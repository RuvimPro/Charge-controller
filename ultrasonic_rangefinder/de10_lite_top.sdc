# -------------------------------------------------------------------------- #
# Synopsys Design Constraints (.sdc)
# Project: Ultrasonic Rangefinder (DE10-Lite)
# -------------------------------------------------------------------------- #

# Установка единиц времени в наносекунды
set_time_format -unit ns -decimal_places 3

# 1. Описание основного тактового сигнала 50 МГц (период 20.0 нс)
create_clock -name {MAX10_CLK1_50} -period 20.000 -waveform { 0.000 10.000 } [get_ports {MAX10_CLK1_50}]

# 2. Автоматический расчет неопределенности тактового сигнала (clock uncertainty)
derive_clock_uncertainty

# 3. Исключение асинхронных входов из временного анализа (False Paths)
# Кнопки KEY, переключатели SW и вход Echo (GPIO[1]) приходят асинхронно
# и синхронизируются внутри ПЛИС двухступенчатыми триггерами (input_sync и rst_chain).
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from [get_ports {GPIO[1]}] -to [all_registers]

# 4. Исключение комбинационных сквозных путей (Feedthrough) на светодиоды
# В de10_lite_top.sv: LEDR[0] = SW[0], LEDR[2] = GPIO[1] (echo_sig)
set_false_path -from [get_ports {SW[*]}]   -to [get_ports {LEDR[*]}]
set_false_path -from [get_ports {GPIO[1]}] -to [get_ports {LEDR[*]}]

# 5. Исключение асинхронных выходов визуальной индикации и импульса запуска датчика
# Светодиоды LEDR, семисегментные индикаторы HEX0..HEX5 и выход Trig (GPIO[0])
# не имеют внешнего тактируемого приемника, синхронного с MAX10_CLK1_50.
set_false_path -from [all_registers] -to [get_ports {LEDR[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX0[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX1[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX2[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX3[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX4[*]}]
set_false_path -from [all_registers] -to [get_ports {HEX5[*]}]
set_false_path -from [all_registers] -to [get_ports {GPIO[0]}]