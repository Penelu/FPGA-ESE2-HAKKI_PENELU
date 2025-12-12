--?????
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library pll;
use pll.all;

entity telecran is
    port (
        -- FPGA
        i_clk_50: in std_logic;

        -- HDMI
        io_hdmi_i2c_scl       : inout std_logic;
        io_hdmi_i2c_sda       : inout std_logic;
        o_hdmi_tx_clk        : out std_logic;
        o_hdmi_tx_d          : out std_logic_vector(23 downto 0);
        o_hdmi_tx_de         : out std_logic;
        o_hdmi_tx_hs         : out std_logic;
        i_hdmi_tx_int        : in std_logic;
        o_hdmi_tx_vs         : out std_logic;

        -- KEYs
        i_rst_n : in std_logic;
		  
		-- LEDs
		o_leds : out std_logic_vector(9 downto 0);
		o_de10_leds : out std_logic_vector(7 downto 0);

		-- Coder
		i_left_ch_a : in std_logic;
		i_left_ch_b : in std_logic;
		i_left_pb : in std_logic;
		i_right_ch_a : in std_logic;
		i_right_ch_b : in std_logic;
		i_right_pb : in std_logic
    );
end entity telecran;

architecture rtl of telecran is
    -- Encodeur gauche (exemple)
    signal a_d1, a_d2 : std_logic := '0';
    signal b_d1, b_d2 : std_logic := '0';

    signal a_rise, a_fall : std_logic;
    signal b_rise, b_fall : std_logic;

    signal cnt : unsigned(9 downto 0) := (others => '0');
	 signal enc_enable : std_logic := '0';


    component I2C_HDMI_Config 
        port (
            iCLK : in std_logic;
            iRST_N : in std_logic;
            I2C_SCLK : out std_logic;
            I2C_SDAT : inout std_logic;
            HDMI_TX_INT  : in std_logic
        );
    end component;

    component pll 
        port (
            refclk : in std_logic;
            rst : in std_logic;
            outclk_0 : out std_logic;
            locked : out std_logic
        );
    end component;

    constant h_res : natural := 720;
    constant v_res : natural := 480;

    signal s_clk_27 : std_logic;
    signal s_rst_n : std_logic;
begin

    -- Détection des fronts (DOIT être après begin)
    a_rise <= '1' when (a_d1='1' and a_d2='0') else '0';
    a_fall <= '1' when (a_d1='0' and a_d2='1') else '0';

    b_rise <= '1' when (b_d1='1' and b_d2='0') else '0';
    b_fall <= '1' when (b_d1='0' and b_d2='1') else '0';


	 process(i_clk_50, i_rst_n)
    variable counter : natural range 0 to 5000 := 0;
begin
    if (i_rst_n = '0') then
        counter := 0;
        enc_enable <= '0';
    elsif rising_edge(i_clk_50) then
        if (counter = 5000) then
            counter := 0;
            enc_enable <= '1';
        else
            counter := counter + 1;
            enc_enable <= '0';
        end if;
    end if;
end process;
	process(i_clk_50, i_rst_n)
begin
    if (i_rst_n = '0') then
        a_d1 <= '0'; a_d2 <= '0';
        b_d1 <= '0'; b_d2 <= '0';
        cnt  <= (others => '0');

    elsif rising_edge(i_clk_50) then


        -- Comptage SEULEMENT quand enc_enable = '1'
        if enc_enable = '1' then
		          -- Synchronisation TOUJOURS active
        a_d1 <= i_left_ch_a;
        a_d2 <= a_d1;
        b_d1 <= i_left_ch_b;
        b_d2 <= b_d1;
		  
            if (a_rise='1' and b_d1='0') or
               (a_fall='1' and b_d1='1') then
                cnt <= cnt + 1;

            elsif (b_rise='1' and a_d1='0') or
                  (b_fall='1' and a_d1='1') then
                cnt <= cnt - 1;
            end if;
        end if;
    end if;
end process;


    -- PLL HDMI
    pll0 : component pll 
        port map (
            refclk => i_clk_50,
            rst => not(i_rst_n),
            outclk_0 => s_clk_27,
            locked => s_rst_n
        );

    -- Config HDMI
    I2C_HDMI_Config0 : component I2C_HDMI_Config 
        port map (
            iCLK => i_clk_50,
            iRST_N => i_rst_n,
            I2C_SCLK => io_hdmi_i2c_scl,
            I2C_SDAT => io_hdmi_i2c_sda,
            HDMI_TX_INT => i_hdmi_tx_int
        );

    -- Affichage LEDs
    o_leds <= std_logic_vector(cnt);
	 o_de10_leds <= (others => '0');
	 
end architecture rtl;
