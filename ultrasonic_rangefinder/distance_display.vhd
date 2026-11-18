library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity distance_display is
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;  -- синхронный сброс (активный '1')
        dist   : in  std_logic_vector(11 downto 0); -- расстояние в мм
        strobe : in  std_logic;  
        err    : in  std_logic;
        HEX0   : out std_logic_vector(7 downto 0) := "10111111"; 
        HEX1   : out std_logic_vector(7 downto 0) := "10111111"; 
        HEX2   : out std_logic_vector(7 downto 0) := "10111111"; 
        HEX3   : out std_logic_vector(7 downto 0) := "10111111"  
    );
end entity;

architecture rtl of distance_display is
    subtype bcd_t is unsigned(15 downto 0);
    subtype seg_t is std_logic_vector(7 downto 0);

    constant BLANK : seg_t := "11111111"; -- все сегменты погашены
    constant DASH  : seg_t := "10111111"; -- символ '-' (горит сегмент 6)
    constant SEG_E : seg_t := "10000110"; -- буква E
    constant SEG_R : seg_t := "10101111"; -- буква r

    function bin_to_bcd(bin : std_logic_vector(11 downto 0))
        return bcd_t is
        variable bcd : bcd_t;
    begin
        bcd := (others => '0');
        for i in 11 downto 0 loop
            for digit in 0 to 3 loop
                if bcd(digit*4+3 downto digit*4) >= 5 then
                    bcd(digit*4+3 downto digit*4) := bcd(digit*4+3 downto digit*4) + 3;
                end if;
            end loop;
            bcd := bcd(14 downto 0) & bin(i);
        end loop;
        return bcd;
    end function;               

    function to_segments(digit : unsigned(3 downto 0))
        return seg_t is
    begin
        case to_integer(digit) is
            when 0      => return "11000000";
            when 1      => return "11111001";
            when 2      => return "10100100";
            when 3      => return "10110000";
            when 4      => return "10011001";
            when 5      => return "10010010";
            when 6      => return "10000010";
            when 7      => return "11111000";
            when 8      => return "10000000";
            when 9      => return "10010000";
            when others => return BLANK;
        end case;
    end function;

begin
    process(clk)
        variable digits : bcd_t;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- По ТЗ после нажатия reset отображается "----"
                HEX0 <= DASH;
                HEX1 <= DASH;
                HEX2 <= DASH;
                HEX3 <= DASH;
            elsif strobe = '1' then
                if err = '1' then
                    HEX3 <= BLANK;
                    HEX2 <= SEG_E;
                    HEX1 <= SEG_R;
                    HEX0 <= SEG_R;
                else
                    digits := bin_to_bcd(dist);
                    HEX0 <= to_segments(digits(3 downto 0));
                    HEX1 <= to_segments(digits(7 downto 4));
                    HEX2 <= to_segments(digits(11 downto 8));
                    HEX3 <= to_segments(digits(15 downto 12));
                    
                    if digits(15 downto 4) = 0 then
                        HEX1 <= BLANK;
                    end if;
                    if digits(15 downto 8) = 0 then
                        HEX2 <= BLANK;
                    end if;
                    if digits(15 downto 12) = 0 then
                        HEX3 <= BLANK;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;