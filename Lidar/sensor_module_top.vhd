library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- Модуль: sensor_module_top (Модуль №1)
-- Описание: Верхний уровень блока опроса ультразвукового датчика HC-SR04
--           и фильтрации данных для платы DE10-Lite (частота 100 МГц).
-- =============================================================================
entity sensor_module_top is
    generic (
        G_TRIG_CLKS         : positive := 1_000;      -- 10 мкс (1000 тактов при 100 МГц)
        G_CLKS_PER_MM       : positive := 580;        -- 5.8 мкс/мм (580 тактов при 100 МГц)
        G_WAIT_ECHO_TIMEOUT : positive := 500_000;    -- Таймаут ожидания Echo (5 мс)
        G_MIN_PAUSE_CLKS    : positive := 6_000_000;  -- Минимальная пауза 60 мс
        G_MEAS_PERIOD_CLKS  : positive := 10_000_000; -- Период одиночного замера 100 мс
        G_FILTER_SAMPLES    : positive := 10;         -- 10 замеров за 1 с (усреднение 8)
        G_MIN_DIST_MM       : natural  := 20;         -- Минимальная дистанция 20 мм
        G_MAX_DIST_MM       : natural  := 4000        -- Максимальная дистанция 4000 мм
    );
    port (
        -- Системные сигналы
        clk       : in  std_logic;                      -- Тактовый сигнал 100 МГц
        reset     : in  std_logic;                      -- Сброс (активный уровень '1')
        switch    : in  std_logic;                      -- Включение опроса датчика ('1' - вкл)

        -- Физический интерфейс датчика HC-SR04
        echo      : in  std_logic;                      -- Входной импульс Echo от датчика
        trig      : out std_logic;                      -- Выходной импульс Trig на датчик

        -- Выходной интерфейс к Модулю №2 (блоку семисегментной индикации)
        dist_mm   : out std_logic_vector(11 downto 0);  -- Измеренное расстояние в мм (20..4000)
        error     : out std_logic;                      -- Сигнал ошибки (выход за диапазон)
        valid_stb : out std_logic                       -- Строб готовности данных (1 такт, 1 Гц)
    );
end entity sensor_module_top;

architecture struct of sensor_module_top is

    -- Регистры двухкаскадной синхронизации (защита от метастабильности)
    signal echo_meta,   echo_sync   : std_logic := '0';
    signal switch_meta, switch_sync : std_logic := '0';

    -- Внутренние сигналы между драйвером и фильтром
    signal raw_dist  : std_logic_vector(11 downto 0);
    signal raw_err   : std_logic;
    signal raw_valid : std_logic;

begin

    -- =========================================================================
    -- 1. Блок синхронизации асинхронных внешних сигналов (2-FF Synchronizer)
    -- =========================================================================
    p_input_sync : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                echo_meta   <= '0';
                echo_sync   <= '0';
                switch_meta <= '0';
                switch_sync <= '0';
            else
                echo_meta   <= echo;
                echo_sync   <= echo_meta;

                switch_meta <= switch;
                switch_sync <= switch_meta;
            end if;
        end if;
    end process p_input_sync;

    -- =========================================================================
    -- 2. Экземпляр драйвера датчика HC-SR04
    -- =========================================================================
    u_hcsr04_driver : entity work.hcsr04_driver
        generic map (
            G_TRIG_CLKS         => G_TRIG_CLKS,
            G_CLKS_PER_MM       => G_CLKS_PER_MM,
            G_WAIT_ECHO_TIMEOUT => G_WAIT_ECHO_TIMEOUT,
            G_MIN_PAUSE_CLKS    => G_MIN_PAUSE_CLKS,
            G_MEAS_PERIOD_CLKS  => G_MEAS_PERIOD_CLKS,
            G_MIN_DIST_MM       => G_MIN_DIST_MM,
            G_MAX_DIST_MM       => G_MAX_DIST_MM
        )
        port map (
            clk_i       => clk,
            rst_i       => reset,
            enable_i    => switch_sync,
            echo_sync_i => echo_sync,
            trig_o      => trig,
            raw_dist_o  => raw_dist,
            raw_err_o   => raw_err,
            raw_valid_o => raw_valid
        );

    -- =========================================================================
    -- 3. Экземпляр фильтра и формирователя секундного строба
    -- =========================================================================
    u_distance_filter : entity work.distance_filter
        generic map (
            G_FILTER_SAMPLES => G_FILTER_SAMPLES,
            G_MAX_ERRORS     => 2
        )
        port map (
            clk_i       => clk,
            rst_i       => reset,
            raw_dist_i  => raw_dist,
            raw_err_i   => raw_err,
            raw_valid_i => raw_valid,
            dist_mm_o   => dist_mm,
            error_o     => error,
            valid_stb_o => valid_stb
        );

end architecture struct;