library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library pll;
use pll.all;

entity telecran_adxl_test is
    port (
        i_clk_50 : in std_logic;

        -- HDMI chip I2C (can keep it, but not required for bars)
        io_hdmi_i2c_scl : inout std_logic;
        io_hdmi_i2c_sda : inout std_logic;
        o_hdmi_tx_clk   : out std_logic;
        o_hdmi_tx_d     : out std_logic_vector(23 downto 0);
        o_hdmi_tx_de    : out std_logic;
        o_hdmi_tx_hs    : out std_logic;
        i_hdmi_tx_int   : in  std_logic;
        o_hdmi_tx_vs    : out std_logic;

        -- ADXL I2C
        io_adxl_scl     : inout std_logic;
        io_adxl_sda     : inout std_logic;

        i_rst_n : in std_logic;

        o_leds      : out std_logic_vector(9 downto 0);
        o_de10_leds : out std_logic_vector(7 downto 0);

        -- buttons (ACTIVE-LOW)
        i_left_pb  : in std_logic;
        i_right_pb : in std_logic
    );
end entity;

architecture rtl of telecran_adxl_test is

    component I2C_HDMI_Config
        port (
            iCLK        : in    std_logic;
            iRST_N      : in    std_logic;
            I2C_SCLK    : out   std_logic;
            I2C_SDAT    : inout std_logic;
            HDMI_TX_INT : in    std_logic
        );
    end component;

    component pll
        port (
            refclk   : in  std_logic;
            rst      : in  std_logic;
            outclk_0 : out std_logic;
            locked   : out std_logic
        );
    end component;

    constant h_res : natural := 720;
    constant v_res : natural := 480;

    signal s_clk_27   : std_logic;
    signal pll_locked : std_logic;
    signal s_rst_n    : std_logic;

    signal s_hs        : std_logic;
    signal s_vs        : std_logic;
    signal s_de        : std_logic;
    signal s_x         : natural range 0 to h_res-1;
    signal s_y         : natural range 0 to v_res-1;

    -- ADXL
    signal s_ax          : signed(15 downto 0);
    signal s_ay          : signed(15 downto 0);
    signal s_ready       : std_logic;

    -- filtered values so motion is slow & visible
    constant ACC_UPDATE_DIV : natural := 50_000_000 / 30; -- ~30Hz
    signal acc_cnt  : natural range 0 to ACC_UPDATE_DIV-1 := 0;
    signal tick_acc : std_logic := '0';

    signal ax_f : signed(15 downto 0) := (others => '0');
    signal ay_f : signed(15 downto 0) := (others => '0');

    signal ax_abs : unsigned(15 downto 0);
    signal ay_abs : unsigned(15 downto 0);

    -- mode switch (0=bars, 1=raw sign view)
    signal mode : std_logic := '0';
    signal rb_d : std_logic := '1';

begin
    --------------------------------------------------------------------
    -- PLL 50 -> 27
    --------------------------------------------------------------------
    pll0 : component pll
        port map (
            refclk   => i_clk_50,
            rst      => not i_rst_n,
            outclk_0 => s_clk_27,
            locked   => pll_locked
        );

    s_rst_n <= i_rst_n and pll_locked;

    --------------------------------------------------------------------
    -- ADV7513 config (keep it so HDMI stays stable)
    --------------------------------------------------------------------
    I2C_HDMI_Config0 : component I2C_HDMI_Config
        port map (
            iCLK        => i_clk_50,
            iRST_N      => i_rst_n,
            I2C_SCLK    => io_hdmi_i2c_scl,
            I2C_SDAT    => io_hdmi_i2c_sda,
            HDMI_TX_INT => i_hdmi_tx_int
        );

    --------------------------------------------------------------------
    -- HDMI timing
    --------------------------------------------------------------------
    u_hdmi : entity work.hdmi_controler
        generic map (
            h_res  => h_res, v_res  => v_res,
            h_sync => 61,    h_fp   => 58, h_bp => 18,
            v_sync => 5,     v_fp   => 30, v_bp => 9
        )
        port map (
            i_clk           => s_clk_27,
            i_rst_n         => s_rst_n,
            o_hdmi_hs       => s_hs,
            o_hdmi_vs       => s_vs,
            o_hdmi_de       => s_de,
            o_x_counter     => s_x,
            o_y_counter     => s_y,
            o_pixel_en      => open,
            o_pixel_address => open
        );

    o_hdmi_tx_clk <= s_clk_27;
    o_hdmi_tx_hs  <= s_hs;
    o_hdmi_tx_vs  <= s_vs;
    o_hdmi_tx_de  <= s_de;

    --------------------------------------------------------------------
    -- ADXL module under test
    --------------------------------------------------------------------
    u_adxl : entity work.adxl345_i2c
        generic map (
            g_clk_hz => 50_000_000,
            g_i2c_hz => 100_000
        )
        port map (
            i_clk   => i_clk_50,
            i_rst_n => i_rst_n,
            io_scl  => io_adxl_scl,
            io_sda  => io_adxl_sda,
            o_ax    => s_ax,
            o_ay    => s_ay,
            o_ready => s_ready
        );

    --------------------------------------------------------------------
    -- Right PB toggles mode (ACTIVE-LOW, simple edge detect)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            rb_d <= '1';
            mode <= '0';
        elsif rising_edge(i_clk_50) then
            if (rb_d = '1' and i_right_pb = '0') then
                mode <= not mode;
            end if;
            rb_d <= i_right_pb;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 30Hz tick for filtering
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            acc_cnt  <= 0;
            tick_acc <= '0';
        elsif rising_edge(i_clk_50) then
            if acc_cnt = ACC_UPDATE_DIV-1 then
                acc_cnt  <= 0;
                tick_acc <= '1';
            else
                acc_cnt  <= acc_cnt + 1;
                tick_acc <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Low-pass filter (only when ready)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
        variable dx : signed(15 downto 0);
        variable dy : signed(15 downto 0);
    begin
        if i_rst_n = '0' then
            ax_f <= (others => '0');
            ay_f <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if tick_acc = '1' and s_ready = '1' then
                dx := s_ax - ax_f;
                dy := s_ay - ay_f;
                ax_f <= ax_f + shift_right(dx, 3); -- /8
                ay_f <= ay_f + shift_right(dy, 3); -- /8
            end if;
        end if;
    end process;

    ax_abs <= unsigned(abs(ax_f));
    ay_abs <= unsigned(abs(ay_f));

    --------------------------------------------------------------------
    -- VIDEO: BARGRAPH VIEW
    -- X bar (green) horizontal centered
    -- Y bar (blue) vertical centered
    --------------------------------------------------------------------
    process(s_de, s_x, s_y, mode, ax_f, ay_f, ax_abs, ay_abs)
        variable cx, cy : integer;
        variable px, py : integer;
        variable barx, bary : integer;
        variable in_barx, in_bary, in_cross : boolean;
    begin
        if s_de = '0' then
            o_hdmi_tx_d <= x"000000";
        else
            cx := h_res/2;
            cy := v_res/2;
            px := integer(s_x);
            py := integer(s_y);

            -- IMPORTANT: use to_integer for Quartus
            barx := to_integer(shift_right(ax_abs, 6)); -- /64
            bary := to_integer(shift_right(ay_abs, 6)); -- /64

            if barx > (h_res/2 - 20) then barx := (h_res/2 - 20); end if;
            if bary > (v_res/2 - 20) then bary := (v_res/2 - 20); end if;

            in_barx := false;
            in_bary := false;

            -- center cross
            in_cross := false;
            if (px >= cx-6 and px <= cx+6 and py >= cy-1 and py <= cy+1) then
                in_cross := true;
            elsif (py >= cy-6 and py <= cy+6 and px >= cx-1 and px <= cx+1) then
                in_cross := true;
            end if;

            -- X bar around center line
            if py >= (cy-2) and py <= (cy+2) then
                if ax_f >= 0 then
                    if px >= cx and px <= (cx + barx) then in_barx := true; end if;
                else
                    if px <= cx and px >= (cx - barx) then in_barx := true; end if;
                end if;
            end if;

            -- Y bar around center column
            if px >= (cx-2) and px <= (cx+2) then
                if ay_f >= 0 then
                    if py >= cy and py <= (cy + bary) then in_bary := true; end if;
                else
                    if py <= cy and py >= (cy - bary) then in_bary := true; end if;
                end if;
            end if;

            if mode = '1' then
                -- MODE 1: show signs only (fast debug)
                -- left half = AX sign, right half = AY sign
                if px < cx then
                    if ax_f < 0 then o_hdmi_tx_d <= x"FF0000"; else o_hdmi_tx_d <= x"00FF00"; end if;
                else
                    if ay_f < 0 then o_hdmi_tx_d <= x"FF0000"; else o_hdmi_tx_d <= x"00FF00"; end if;
                end if;
            else
                -- MODE 0: bars
                if in_cross then
                    o_hdmi_tx_d <= x"FFFFFF";
                elsif in_barx then
                    o_hdmi_tx_d <= x"00FF00";
                elsif in_bary then
                    o_hdmi_tx_d <= x"0000FF";
                else
                    o_hdmi_tx_d <= x"000000";
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- LEDs: you get the accel “data back” here
    --------------------------------------------------------------------
    -- coarse |ax| on o_leds
    o_leds <= std_logic_vector(ax_abs(15 downto 6));

    -- status LEDs
    o_de10_leds(0) <= pll_locked;
    o_de10_leds(1) <= s_ready;          -- MUST go 1 if ADXL init+read ok
    o_de10_leds(2) <= tick_acc;         -- ~30Hz tick
    o_de10_leds(3) <= mode;
    o_de10_leds(4) <= ax_f(15);         -- sign AX
    o_de10_leds(5) <= ay_f(15);         -- sign AY
    o_de10_leds(7 downto 6) <= "00";

end architecture;

