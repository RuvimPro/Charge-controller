library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- Модуль: hcsr04_driver
-- Описание: Драйвер ультразвукового датчика HC-SR04.
--           Обеспечивает генерацию импульса запуска (Trig = 10 мкс),
--           измерение длительности импульса Echo с математическим округлением
--           до ближайшего миллиметра без использования операции деления,
--           контроль рабочего диапазона (20..4000 мм) и выдержку паузы >= 60 мс.
-- =============================================================================
entity hcsr04_driver is
    generic (
        G_TRIG_CLKS         : positive := 1_000;      -- 10 мкс при 100 МГц (1000 тактов)
        G_CLKS_PER_MM       : positive := 580;        -- 5.8 мкс на 1 мм (580 тактов)
        G_WAIT_ECHO_TIMEOUT : positive := 500_000;    -- Таймаут ожидания фронта Echo (5 мс)
        G_MIN_PAUSE_CLKS    : positive := 6_000_000;  -- Минимальная пауза 60 мс (6 000 000 тактов)
        G_MEAS_PERIOD_CLKS  : positive := 10_000_000; -- Полный период одного замера 100 мс
        G_MIN_DIST_MM       : natural  := 20;         -- Минимальное расстояние: 20 мм
        G_MAX_DIST_MM       : natural  := 4000        -- Максимальное расстояние: 4000 мм
    );
    port (
        clk_i        : in  std_logic;                      -- Тактовая частота 100 МГц
        rst_i        : in  std_logic;                      -- Синхронный сброс (активный '1')
        enable_i     : in  std_logic;                      -- Разрешение опроса (от switch)
        echo_sync_i  : in  std_logic;                      -- Синхронизированный сигнал Echo
        trig_o       : out std_logic;                      -- Выходной импульс запуска Trig
        raw_dist_o   : out std_logic_vector(11 downto 0);  -- Измеренное расстояние (мм)
        raw_err_o    : out std_logic;                      -- Флаг ошибки одиночного замера
        raw_valid_o  : out std_logic                       -- Строб завершения одиночного замера (1 такт)
    );
end entity hcsr04_driver;

architecture rtl of hcsr04_driver is

    -- Состояния конечного автомата управления датчиком
    type t_driver_state is (
        ST_IDLE,            -- Ожидание включения опроса (enable_i = '1')
        ST_TRIG_PULSE,      -- Формирование импульса Trig длительностью 10 мкс
        ST_WAIT_ECHO_RISE,  -- Ожидание переднего фронта сигнала Echo
        ST_MEASURE_ECHO,    -- Подсчет миллиметров пока Echo = '1'
        ST_WAIT_ECHO_FALL,  -- Дожидание спада Echo при превышении максимума
        ST_EVALUATE,        -- Округление и проверка границ диапазона (20..4000 мм)
        ST_PAUSE            -- Выдержка паузы между измерениями (>= 60 мс и до 100 мс)
    );

    signal state_reg       : t_driver_state := ST_IDLE;

    -- Счетчик тактов внутри состояний и общего периода измерения
    signal period_cnt      : natural range 0 to G_MEAS_PERIOD_CLKS := 0;
    signal state_timer_cnt : natural range 0 to G_MIN_PAUSE_CLKS   := 0;

    -- Предделитель тактов в миллиметры (0 .. 579)
    signal prescaler_cnt   : natural range 0 to G_CLKS_PER_MM - 1  := 0;

    -- Счетчик миллиметров с запасом на переполнение (до 4001 мм)
    signal mm_cnt          : unsigned(12 downto 0) := (others => '0');

    -- Внутренний флаг ошибки (таймаут или выход за пределы)
    signal meas_error_flag : std_logic := '0';

begin

    -- =========================================================================
    -- Основной синхронный процесс автомата состояний драйвера
    -- =========================================================================
    p_driver_fsm : process(clk_i)
        variable v_final_mm : unsigned(12 downto 0);
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg       <= ST_IDLE;
                period_cnt      <= 0;
                state_timer_cnt <= 0;
                prescaler_cnt   <= 0;
                mm_cnt          <= (others => '0');
                meas_error_flag <= '0';
                trig_o          <= '0';
                raw_dist_o      <= (others => '0');
                raw_err_o       <= '0';
                raw_valid_o     <= '0';
            else
                -- По умолчанию строб готовности равен '0' (формируется ровно на 1 такт)
                raw_valid_o <= '0';

                -- Счетчик полного периода измерения (для равномерного шага 100 мс)
                if state_reg /= ST_IDLE then
                    if period_cnt < G_MEAS_PERIOD_CLKS - 1 then
                        period_cnt <= period_cnt + 1;
                    end if;
                else
                    period_cnt <= 0;
                end if;

                case state_reg is

                    -- ---------------------------------------------------------
                    -- 1. Ожидание разрешения работы (switch = '1')
                    -- ---------------------------------------------------------
                    when ST_IDLE =>
                        trig_o          <= '0';
                        state_timer_cnt <= 0;
                        prescaler_cnt   <= 0;
                        mm_cnt          <= (others => '0');
                        meas_error_flag <= '0';

                        if enable_i = '1' then
                            trig_o    <= '1';
                            state_reg <= ST_TRIG_PULSE;
                        end if;

                    -- ---------------------------------------------------------
                    -- 2. Генерация стартового импульса Trig (10 мкс)
                    -- ---------------------------------------------------------
                    when ST_TRIG_PULSE =>
                        if state_timer_cnt < G_TRIG_CLKS - 1 then
                            trig_o          <= '1';
                            state_timer_cnt <= state_timer_cnt + 1;
                        else
                            trig_o          <= '0';
                            state_timer_cnt <= 0;
                            state_reg       <= ST_WAIT_ECHO_RISE;
                        end if;

                    -- ---------------------------------------------------------
                    -- 3. Ожидание начала импульса Echo (с защитой по таймауту)
                    -- ---------------------------------------------------------
                    when ST_WAIT_ECHO_RISE =>
                        if echo_sync_i = '1' then
                            -- Первый такт высокого уровня Echo уже зафиксирован:
                            -- инициализируем предделитель единицей для 100% точности
                            prescaler_cnt   <= 1;
                            mm_cnt          <= (others => '0');
                            state_timer_cnt <= 0;
                            state_reg       <= ST_MEASURE_ECHO;
                        elsif state_timer_cnt < G_WAIT_ECHO_TIMEOUT - 1 then
                            state_timer_cnt <= state_timer_cnt + 1;
                        else
                            -- Датчик не ответил в течение 5 мс -> ошибка
                            meas_error_flag <= '1';
                            state_timer_cnt <= 0;
                            state_reg       <= ST_EVALUATE;
                        end if;

                    -- ---------------------------------------------------------
                    -- 4. Измерение длительности импульса Echo напрямую в мм
                    -- ---------------------------------------------------------
                    when ST_MEASURE_ECHO =>
                        if echo_sync_i = '1' then
                            -- Проверка на превышение максимальной дальности (4000 мм)
                            if mm_cnt > G_MAX_DIST_MM then
                                meas_error_flag <= '1';
                                state_timer_cnt <= 0;
                                state_reg       <= ST_WAIT_ECHO_FALL;
                            else
                                if prescaler_cnt = G_CLKS_PER_MM - 1 then
                                    prescaler_cnt <= 0;
                                    mm_cnt        <= mm_cnt + 1;
                                else
                                    prescaler_cnt <= prescaler_cnt + 1;
                                end if;
                            end if;
                        else
                            -- Сигнал Echo завершился штатно
                            state_reg <= ST_EVALUATE;
                        end if;

                    -- ---------------------------------------------------------
                    -- 5. Ожидание спада слишком длинного импульса Echo
                    --    (со сторожевым таймером от залипания линии в '1')
                    -- ---------------------------------------------------------
                    when ST_WAIT_ECHO_FALL =>
                        if echo_sync_i = '0' or (state_timer_cnt >= G_MIN_PAUSE_CLKS - 1) then
                            state_timer_cnt <= 0;
                            state_reg       <= ST_EVALUATE;
                        else
                            state_timer_cnt <= state_timer_cnt + 1;
                        end if;

                    -- ---------------------------------------------------------
                    -- 6. Округление результата и проверка диапазона 20..4000 мм
                    -- ---------------------------------------------------------
                    when ST_EVALUATE =>
                        -- Математическое округление до ближайшего миллиметра:
                        -- если остаток тактов >= половины мм (290 тактов), прибавляем 1 мм
                        if prescaler_cnt >= (G_CLKS_PER_MM / 2) then
                            v_final_mm := mm_cnt + 1;
                        else
                            v_final_mm := mm_cnt;
                        end if;

                        -- Проверка попадания в допустимый диапазон 20..4000 мм
                        if (meas_error_flag = '1') or
                           (v_final_mm < G_MIN_DIST_MM) or
                           (v_final_mm > G_MAX_DIST_MM) then
                            raw_dist_o <= (others => '0');
                            raw_err_o  <= '1';
                        else
                            raw_dist_o <= std_logic_vector(v_final_mm(11 downto 0));
                            raw_err_o  <= '0';
                        end if;

                        raw_valid_o     <= '1'; -- Строб готовности замера (1 такт)
                        state_timer_cnt <= 0;
                        state_reg       <= ST_PAUSE;

                    -- ---------------------------------------------------------
                    -- 7. Пауза между измерениями:
                    --    выдерживается минимум 60 мс И до конца периода 100 мс
                    -- ---------------------------------------------------------
                    when ST_PAUSE =>
                        if state_timer_cnt < G_MIN_PAUSE_CLKS - 1 then
                            state_timer_cnt <= state_timer_cnt + 1;
                        elsif period_cnt < G_MEAS_PERIOD_CLKS - 1 then
                            -- Ждем завершения полного 100 мс слота для синхронности
                            null;
                        else
                            state_timer_cnt <= 0;
                            state_reg       <= ST_IDLE;
                        end if;

                    -- Защита от сбоев состояний
                    when others =>
                        state_reg <= ST_IDLE;

                end case;
            end if;
        end if;
    end process p_driver_fsm;

end architecture rtl;