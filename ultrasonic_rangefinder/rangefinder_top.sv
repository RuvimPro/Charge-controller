//------------------------------------------------------------------------------
// Файл       : rangefinder_top.sv
// Модуль     : rangefinder_top — МОДУЛЬ 1: опрос датчика HC-SR04, фильтрация,
//              выдача расстояния в миллиметрах (частота 50 МГц)
//
// Состав (порядок компиляции)
//   1. rangefinder_pkg.sv     — общие константы и функции
//   2. input_sync.sv          — синхронизация switch, reset, echo
//   3. hcsr04_driver.sv       — одно измерение датчика
//   4. median_avg_filter.sv   — 10 замеров -> 1 результат
//   5. rangefinder_top.sv     — этот файл
//
// Структура
//
//   sw_en, reset, echo --> [input_sync] --sw_s, rst_s, echo_s-->
//                                                             |
//     [планировщик 100 мс] --start--> [hcsr04_driver] --> trig (на датчик)
//                                          | done, dist, err
//                                          v
//                                 [median_avg_filter] --> dist_mm, err, strobe
//
// Как работает
//   * Пока switch включён, планировщик каждые 100 мс (10 замеров в секунду)
//     запускает драйвер; первый замер стартует сразу после включения switch.
//   * Период 100 мс гарантирует паузу между замерами не менее 60 мс
//     (требование даташита).
//   * Фильтр собирает 10 замеров и раз в секунду выдаёт результат:
//       dist_mm — расстояние в мм (12 бит),
//       err     — '1', если хотя бы один замер за эту секунду вне диапазона
//                 20..4000 мм или датчик не ответил (тогда dist_mm = 0),
//       strobe  — '1' на один такт: dist_mm и err обновились.
//     Между стробами dist_mm и err не меняются.
//   * Выключили switch — опрос прекращается, замер прерывается, окно фильтра
//     очищается; последний результат на выходе сохраняется.
//   * reset (нажатие кнопки) — синхронный сброс всего модуля.
//
// Частота и временные параметры
//   Все временные константы вычисляются из CLK_FREQ_HZ (при 50 МГц).
//
// Электрическое замечание: выход Echo датчика — 5 В, входы MAX 10 — 3,3 В.
// Нужен резистивный делитель или преобразователь уровней.
//
// Для платы: кнопки KEY на DE10-Lite активны по низкому уровню, поэтому
// на вход reset подавайте инвертированный сигнал (reset = ~KEY[0]).
//------------------------------------------------------------------------------
module rangefinder_top #(
  parameter int CLK_FREQ_HZ = 50_000_000   // штатная частота DE10-Lite: 50 МГц
) (
  input  logic                                   clk,      // тактовая частота 50 МГц
  input  logic                                   reset,    // кнопка сброса, активный уровень '1' (асинхронная)
  input  logic                                   sw_en,    // switch: '1' — опрашивать датчик (асинхронный)
  input  logic                                   echo,     // выход Echo датчика (асинхронный)

  output logic                                   trig,     // вход Trig датчика
  output logic [rangefinder_pkg::DIST_WIDTH-1:0] dist_mm,  // расстояние, мм
  output logic                                   err,      // расстояние вне диапазона (за секунду была хоть одна ошибка)
  output logic                                   strobe    // строб готовности данных, 1 такт
);

  import rangefinder_pkg::*;

  //----------------------------------------------------------------------------
  // Временные константы (в тактах)
  //----------------------------------------------------------------------------
  // 1 мм дистанции = 2 мм пути звука: 2 / 340 м/с = 5,88 мкс = 294 такта при 50 МГц (сколько тактов на 1 мм)
  localparam int CLK_PER_MM     = CLK_FREQ_HZ / 170_000;
  // Импульс trig: 12 мкс = 600 тактов при 50 МГц
  localparam int TRIG_CLKS      = (CLK_FREQ_HZ / 1_000_000) * 12;
  // Время ожидания начала эха: 2 мс = 100 000 тактов при 50 МГц
  // localparam int ECHO_WAIT_CLKS = (CLK_FREQ_HZ / 1_000) * 2;
  localparam int ECHO_WAIT_CLKS = (CLK_FREQ_HZ / 1_000) * 10; // 10 мс запас на задержку старта Echo
  // Период опроса: 100 мс = 5 000 000 тактов при 50 МГц (10 замеров в секунду)
  localparam int PERIOD_CLKS    = CLK_FREQ_HZ / 10;
  // Минимальная пауза между замерами по даташиту: 60 мс = 3 000 000 тактов
  localparam int MIN_PAUSE_CLKS = (CLK_FREQ_HZ / 1_000) * 60;
  // Самое длинное эхо, которое мы дожидаемся (на 1 мм больше максимума)
  localparam int MAX_ECHO_CLKS  = (DEFAULT_DIST_MAX_MM + 1) * CLK_PER_MM;

  // Разрядность и предел счётчика периода опроса (0 .. PERIOD_CLKS - 1)
  localparam int PERIOD_W = bit_width(PERIOD_CLKS - 1);
  typedef logic [PERIOD_W-1:0] period_t;
  localparam period_t PERIOD_LAST = period_t'(PERIOD_CLKS - 1);

 

  //----------------------------------------------------------------------------
  // Внутренние сигналы и регистры
  //----------------------------------------------------------------------------
  // Синхронизированные входы
  logic sw_s;
  logic rst_s;
  logic echo_s;

  // Планировщик
  period_t period_reg = '0, period_next;
  logic    start; // 10 раз в секунду пинать драйвер (выставляет '1' на один такт)

  // Результат одного измерения (драйвер -> фильтр)
  logic                  drv_done;
  logic [DIST_WIDTH-1:0] drv_dist;
  logic                  drv_err;

  //============================================================================
  // 1. Синхронизация асинхронных входов
  //============================================================================
  input_sync u_sync (
    .clk        (clk),
    .sw_async   (sw_en),
    .rst_async  (reset),
    .echo_async (echo),
    .sw_sync    (sw_s),
    .rst_sync   (rst_s),
    .echo_sync  (echo_s)
  );

  //============================================================================
  // 2. Планировщик: импульс start раз в PERIOD_CLKS тактов, пока switch включён
  //============================================================================
  always_ff @(posedge clk) begin : p_period_reg
    if (rst_s) begin
      period_reg <= '0;
    end else begin
      period_reg <= period_next;
    end
  end

  always_comb begin : p_period_next
    if (!sw_s) begin
      period_next = '0;
    end else if (period_reg == PERIOD_LAST) begin
      period_next = '0;
    end else begin
      period_next = period_reg + 1'b1;
    end
  end

  assign start = sw_s & (period_reg == '0);

  //============================================================================
  // 3. Драйвер: одно измерение по команде start
  //============================================================================
  hcsr04_driver #(
    .CLK_PER_MM     (CLK_PER_MM),
    .TRIG_CLKS      (TRIG_CLKS),
    .ECHO_WAIT_CLKS (ECHO_WAIT_CLKS)
  ) u_driver (
    .clk     (clk),
    .rst     (rst_s),
    .en      (sw_s),
    .start   (start),
    .echo    (echo_s),
    .trig    (trig),
    .done    (drv_done),
    .dist_mm (drv_dist),
    .err     (drv_err)
  );

  //============================================================================
  // 4. Фильтр: 10 замеров -> одно значение раз в секунду
  //============================================================================
  median_avg_filter #(
    .DIST_WIDTH (DIST_WIDTH)
  ) u_filter (
    .clk     (clk),
    .rst     (rst_s),
    .en      (sw_s),
    .s_valid (drv_done),
    .s_dist  (drv_dist),
    .s_err   (drv_err),
    .dist_mm (dist_mm),
    .err     (err),
    .strobe  (strobe)
  );

endmodule : rangefinder_top