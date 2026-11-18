library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- Модуль: distance_filter
-- Описание: Фильтр измерений расстояния (усеченное среднее по 10 выборкам).
--           При G_FILTER_SAMPLES = 10 накапливает 10 замеров (за 1 секунду),
--           отбрасывает минимум и максимум, усредняет оставшиеся 8 значений
--           сдвигом вправо на 3 бита и выдает строб готовности на 1 такт.
--           При G_FILTER_SAMPLES = 1 работает в режиме прямого прохода.
-- =============================================================================
entity distance_filter is
    generic (
        G_FILTER_SAMPLES : positive := 10; -- Число выборок в окне (10 или 1 для обхода)
        G_MAX_ERRORS     : natural  := 2   -- Допустимое число ошибок в окне из 10 замеров
    );
    port (
        clk_i        : in  std_logic;                      -- Тактовая частота 100 МГц
        rst_i        : in  std_logic;                      -- Синхронный сброс (активный '1')
        raw_dist_i   : in  std_logic_vector(11 downto 0);  -- Входное расстояние от драйвера
        raw_err_i    : in  std_logic;                      -- Входной флаг ошибки от драйвера
        raw_valid_i  : in  std_logic;                      -- Входной строб от драйвера
        dist_mm_o    : out std_logic_vector(11 downto 0);  -- Отфильтрованное расстояние (мм)
        error_o      : out std_logic;                      -- Выходной сигнал ошибки (error)
        valid_stb_o  : out std_logic                       -- Строб готовности данных (1 такт)
    );
end entity distance_filter;

architecture rtl of distance_filter is

    type t_filter_state is (
        ST_COLLECT,  -- Накопление выборок
        ST_COMPUTE   -- Вычисление усеченного среднего и выдача результата
    );

    signal state_reg   : t_filter_state := ST_COLLECT;

    -- Счетчики общего числа выборок, валидных выборок и ошибок в текущем окне
    signal total_cnt   : natural range 0 to G_FILTER_SAMPLES := 0;
    signal valid_cnt   : natural range 0 to G_FILTER_SAMPLES := 0;
    signal err_cnt     : natural range 0 to G_FILTER_SAMPLES := 0;

    -- Аккумулятор суммы (до 10 * 4000 = 40000 -> требуется 16 бит)
    signal sum_acc     : unsigned(15 downto 0) := (others => '0');

    -- Регистры минимума и максимума для отбрасывания промахов
    signal min_val     : unsigned(11 downto 0) := (others => '1');
    signal max_val     : unsigned(11 downto 0) := (others => '0');

    -- Последнее валидное значение (на случай малого числа выборок)
    signal last_valid  : unsigned(11 downto 0) := (others => '0');

begin

    p_filter : process(clk_i)
        variable v_sample      : unsigned(11 downto 0);
        variable v_trimmed_sum : unsigned(15 downto 0);
        variable v_avg_result  : unsigned(11 downto 0);
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg   <= ST_COLLECT;
                total_cnt   <= 0;
                valid_cnt   <= 0;
                err_cnt     <= 0;
                sum_acc     <= (others => '0');
                min_val     <= (others => '1');
                max_val     <= (others => '0');
                last_valid  <= (others => '0');
                dist_mm_o   <= (others => '0');
                error_o     <= '0';
                valid_stb_o <= '0';
            else
                -- Строб готовности всегда равен '0', кроме одного такта выдачи
                valid_stb_o <= '0';

                case state_reg is

                    -- ---------------------------------------------------------
                    -- 1. Прием и накопление измерений от драйвера
                    -- ---------------------------------------------------------
                    when ST_COLLECT =>
                        if raw_valid_i = '1' then
                            v_sample := unsigned(raw_dist_i);

                            -- Режим без фильтрации (G_FILTER_SAMPLES = 1)
                            if G_FILTER_SAMPLES = 1 then
                                if raw_err_i = '1' then
                                    dist_mm_o <= (others => '0');
                                    error_o   <= '1';
                                else
                                    dist_mm_o <= raw_dist_i;
                                    error_o   <= '0';
                                end if;
                                valid_stb_o <= '1';
                            else
                                -- Штатный режим накопления выборки
                                if raw_err_i = '1' then
                                    err_cnt <= err_cnt + 1;
                                else
                                    valid_cnt  <= valid_cnt + 1;
                                    last_valid <= v_sample;
                                    sum_acc    <= sum_acc + resize(v_sample, 16);

                                    if v_sample < min_val then
                                        min_val <= v_sample;
                                    end if;

                                    if v_sample > max_val then
                                        max_val <= v_sample;
                                    end if;
                                end if;

                                -- Проверка завершения секундного окна выборок
                                if total_cnt = G_FILTER_SAMPLES - 1 then
                                    state_reg <= ST_COMPUTE;
                                else
                                    total_cnt <= total_cnt + 1;
                                end if;
                            end if;
                        end if;

                    -- ---------------------------------------------------------
                    -- 2. Расчет среднего значения и формирование выходного строба
                    -- ---------------------------------------------------------
                    when ST_COMPUTE =>
                        if valid_cnt = 10 then
                            -- Все 10 замеров успешны: вычитаем min и max,
                            -- делим сумму 8 оставшихся замеров на 8 (сдвиг >> 3) + округление
                            v_trimmed_sum := sum_acc - resize(min_val, 16) - resize(max_val, 16) + 4;
                            v_avg_result  := v_trimmed_sum(14 downto 3);
                            dist_mm_o     <= std_logic_vector(v_avg_result);
                            error_o       <= '0';
                        elsif (err_cnt <= G_MAX_ERRORS) and (valid_cnt >= 8) then
                            -- Было 1..2 одиночных сбоя, но есть минимум 8 валидных замеров:
                            -- если ровно 8 валидных, берем их среднее напрямую
                            if valid_cnt = 8 then
                                v_trimmed_sum := sum_acc + 4;
                            else -- valid_cnt = 9 (отбрасываем только максимальный выброс)
                                v_trimmed_sum := sum_acc - resize(max_val, 16) + 4;
                            end if;
                            v_avg_result := v_trimmed_sum(14 downto 3);
                            dist_mm_o    <= std_logic_vector(v_avg_result);
                            error_o      <= '0';
                        elsif (err_cnt = 0) and (valid_cnt > 0) then
                            -- На случай нестандартного G_FILTER_SAMPLES в симуляции
                            dist_mm_o <= std_logic_vector(last_valid);
                            error_o   <= '0';
                        else
                            -- Превышен порог ошибок за секунду -> выдаем сигнал error
                            dist_mm_o <= (others => '0');
                            error_o   <= '1';
                        end if;

                        valid_stb_o <= '1'; -- Выходной строб длительностью ровно 1 такт

                        -- Сброс аккумуляторов перед следующим секундным циклом
                        total_cnt <= 0;
                        valid_cnt <= 0;
                        err_cnt   <= 0;
                        sum_acc   <= (others => '0');
                        min_val   <= (others => '1');
                        max_val   <= (others => '0');
                        state_reg <= ST_COLLECT;

                    when others =>
                        state_reg <= ST_COLLECT;

                end case;
            end if;
        end if;
    end process p_filter;

end architecture rtl;