library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library pll;
use pll.all;

entity telecran is
    port (
        i_clk_50 : in std_logic;

        io_hdmi_i2c_scl : inout std_logic;
        io_hdmi_i2c_sda : inout std_logic;
        o_hdmi_tx_clk   : out std_logic;
        o_hdmi_tx_d     : out std_logic_vector(23 downto 0);
        o_hdmi_tx_de    : out std_logic;
        o_hdmi_tx_hs    : out std_logic;
        i_hdmi_tx_int   : in  std_logic;
        o_hdmi_tx_vs    : out std_logic;

        io_adxl_scl     : inout std_logic;
        io_adxl_sda     : inout std_logic;

        i_rst_n : in std_logic;

        o_leds      : out std_logic_vector(9 downto 0);
        o_de10_leds : out std_logic_vector(7 downto 0);

        i_left_ch_a  : in std_logic;
        i_left_ch_b  : in std_logic;
        i_left_pb    : in std_logic;  -- ACTIVE-LOW
        i_right_ch_a : in std_logic;
        i_right_ch_b : in std_logic;
        i_right_pb   : in std_logic   -- ACTIVE-LOW
    );
end entity telecran;

architecture rtl of telecran is

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

    constant h_res   : natural := 720;
    constant v_res   : natural := 480;
    constant FB_SIZE : natural := h_res * v_res;

    signal s_clk_27   : std_logic;
    signal pll_locked : std_logic;
    signal s_rst_n    : std_logic;

    signal s_hs        : std_logic;
    signal s_vs        : std_logic;
    signal s_de        : std_logic;
    signal s_x_counter : natural range 0 to h_res-1;
    signal s_y_counter : natural range 0 to v_res-1;

    -- encoders
    signal a_d1, a_d2 : std_logic := '0';
    signal b_d1, b_d2 : std_logic := '0';
    signal ra_d1, ra_d2 : std_logic := '0';
    signal rb_d1, rb_d2 : std_logic := '0';
    signal a_rise, a_fall : std_logic;
    signal b_rise, b_fall : std_logic;
    signal ra_rise, ra_fall : std_logic;
    signal rb_rise, rb_fall : std_logic;

    signal cnt_x : unsigned(9 downto 0) := (others => '0');
    signal cnt_y : unsigned(8 downto 0) := (others => '0');

    signal enc_enable : std_logic := '0';

    signal s_x_pos : natural range 0 to h_res-1 := 0;
    signal s_y_pos : natural range 0 to v_res-1 := 0;

    signal s_rd_addr : natural range 0 to FB_SIZE-1;

    signal s_fb_q_a : std_logic_vector(7 downto 0);
    signal s_fb_q_b : std_logic_vector(7 downto 0);

    -- clear
    signal s_clr_en   : std_logic := '1';
    signal s_clr_addr : natural range 0 to FB_SIZE-1 := 0;

    signal s_we_a   : std_logic;
    signal s_addr_a : natural range 0 to FB_SIZE-1;
    signal s_data_a : std_logic_vector(7 downto 0);

    -- clear done pulse
    signal clr_en_d  : std_logic := '1';
    signal clr_done_pulse : std_logic := '0';

    -- ADXL
    signal s_ax          : signed(15 downto 0);
    signal s_ay          : signed(15 downto 0);
    signal s_accel_ready : std_logic;

    -- accel ok latch (fixes "ready pulses")
    signal accel_ok : std_logic := '0';

    -- sampling tick ~30 Hz
    constant ACC_UPDATE_DIV : natural := 50_000_000 / 30;
    signal acc_cnt  : natural range 0 to ACC_UPDATE_DIV-1 := 0;
    signal tick_acc : std_logic := '0';

    -- sampled accel (stable for game + display)
    signal ax_samp : signed(15 downto 0) := (others => '0');
    signal ay_samp : signed(15 downto 0) := (others => '0');

    -- scaled accel for game
    signal ax_game : signed(15 downto 0) := (others => '0');
    signal ay_game : signed(15 downto 0) := (others => '0');

    -- game engine outputs
    signal g_we   : std_logic;
    signal g_addr : natural range 0 to FB_SIZE-1;
    signal g_data : std_logic_vector(7 downto 0);

    -- controls (ACTIVE-LOW buttons)
    signal s_greset_user  : std_logic;
    signal s_greset_final : std_logic;

    -- DEBUG MODE (00/01/10/11)
    signal debug_mode : unsigned(1 downto 0) := "00";

    -- Debounce RIGHT PB (ACTIVE-LOW)
    signal rb_sync0, rb_sync1 : std_logic := '1';
    signal rb_stable          : std_logic := '1';
    signal rb_stable_d        : std_logic := '1';
    signal rb_cnt             : unsigned(19 downto 0) := (others => '0'); -- ~20ms

    -- diagnostics
    signal any_we : std_logic := '0';

    -- helpers for bars
    signal ax_abs_u : unsigned(15 downto 0);
    signal ay_abs_u : unsigned(15 downto 0);

    --------------------------------------------------------------------
    -- TUNING CONSTANTS (adjust these)
    --------------------------------------------------------------------
    constant DEAD_BAND    : natural := 20;  -- ignore tiny noise (LSB)
    constant GAIN_SHIFT   : natural := 5;   -- multiply by 2^GAIN_SHIFT (5 => x32)
    constant SAT_LIMIT    : natural := 6000;-- after gain, clamp to +/-SAT_LIMIT

begin
    --------------------------------------------------------------------
    -- LEFT PB is ACTIVE-LOW: pressed => reset asserted
    --------------------------------------------------------------------
    s_greset_user <= not i_left_pb;

    --------------------------------------------------------------------
    -- Debounced RIGHT PB cycles debug_mode on PRESS (stable 1->0)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            rb_sync0    <= '1';
            rb_sync1    <= '1';
            rb_stable   <= '1';
            rb_stable_d <= '1';
            rb_cnt      <= (others => '0');
            debug_mode  <= "00";
        elsif rising_edge(i_clk_50) then
            rb_sync0 <= i_right_pb;
            rb_sync1 <= rb_sync0;

            if rb_sync1 = rb_stable then
                rb_cnt <= (others => '0');
            else
                rb_cnt <= rb_cnt + 1;
                if rb_cnt = to_unsigned(1_000_000, rb_cnt'length) then
                    rb_stable <= rb_sync1;
                    rb_cnt <= (others => '0');
                end if;
            end if;

            rb_stable_d <= rb_stable;
            if (rb_stable_d = '1' and rb_stable = '0') then
                debug_mode <= debug_mode + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- PLL 50MHz -> 27MHz
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
    -- ADV7513 config (HDMI)
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
    u_hdmi_ctrl : entity work.hdmi_controler
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
            o_x_counter     => s_x_counter,
            o_y_counter     => s_y_counter,
            o_pixel_en      => open,
            o_pixel_address => open
        );

    o_hdmi_tx_clk <= s_clk_27;
    o_hdmi_tx_hs  <= s_hs;
    o_hdmi_tx_vs  <= s_vs;
    o_hdmi_tx_de  <= s_de;

    --------------------------------------------------------------------
    -- enc_enable ~1ms @50MHz
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
        variable counter : natural range 0 to 4999 := 0;
    begin
        if i_rst_n = '0' then
            counter := 0;
            enc_enable <= '0';
        elsif rising_edge(i_clk_50) then
            if counter = 4999 then
                counter := 0;
                enc_enable <= '1';
            else
                counter := counter + 1;
                enc_enable <= '0';
            end if;
        end if;
    end process;

    a_rise  <= '1' when (a_d1='1' and a_d2='0') else '0';
    a_fall  <= '1' when (a_d1='0' and a_d2='1') else '0';
    b_rise  <= '1' when (b_d1='1' and b_d2='0') else '0';
    b_fall  <= '1' when (b_d1='0' and b_d2='1') else '0';

    ra_rise <= '1' when (ra_d1='1' and ra_d2='0') else '0';
    ra_fall <= '1' when (ra_d1='0' and ra_d2='1') else '0';
    rb_rise <= '1' when (rb_d1='1' and rb_d2='0') else '0';
    rb_fall <= '1' when (rb_d1='0' and rb_d2='1') else '0';

    -- LEFT encoder updates cnt_x
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            a_d1 <= '0'; a_d2 <= '0';
            b_d1 <= '0'; b_d2 <= '0';
            cnt_x <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if enc_enable = '1' then
                a_d1 <= i_left_ch_a;  a_d2 <= a_d1;
                b_d1 <= i_left_ch_b;  b_d2 <= b_d1;

                if ((a_rise='1' and b_d1='0') or (a_fall='1' and b_d1='1')) then
                    cnt_x <= cnt_x + 1;
                elsif ((b_rise='1' and a_d1='0') or (b_fall='1' and a_d1='1')) then
                    cnt_x <= cnt_x - 1;
                end if;
            end if;
        end if;
    end process;

    -- RIGHT encoder updates cnt_y
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            ra_d1 <= '0'; ra_d2 <= '0';
            rb_d1 <= '0'; rb_d2 <= '0';
            cnt_y <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if enc_enable = '1' then
                ra_d1 <= i_right_ch_a; ra_d2 <= ra_d1;
                rb_d1 <= i_right_ch_b; rb_d2 <= rb_d1;

                if ((ra_rise='1' and rb_d1='0') or (ra_fall='1' and rb_d1='1')) then
                    cnt_y <= cnt_y + 1;
                elsif ((rb_rise='1' and ra_d1='0') or (rb_fall='1' and ra_d1='1')) then
                    cnt_y <= cnt_y - 1;
                end if;
            end if;
        end if;
    end process;

    -- clamp
    process(cnt_x, cnt_y)
        variable vx : natural;
        variable vy : natural;
    begin
        vx := to_integer(cnt_x);
        vy := to_integer(cnt_y);

        if vx >= h_res then s_x_pos <= h_res-1; else s_x_pos <= vx; end if;
        if vy >= v_res then s_y_pos <= v_res-1; else s_y_pos <= vy; end if;
    end process;

    -- framebuffer read address from HDMI counters
    s_rd_addr <= s_y_counter * h_res + s_x_counter;

    --------------------------------------------------------------------
    -- Clear framebuffer at startup only (writes stripes 01/00)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            s_clr_en   <= '1';
            s_clr_addr <= 0;
        elsif rising_edge(i_clk_50) then
            if s_clr_en = '1' then
                if s_clr_addr = FB_SIZE-1 then
                    s_clr_en <= '0';
                else
                    s_clr_addr <= s_clr_addr + 1;
                end if;
            end if;
        end if;
    end process;

    -- clear done pulse
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            clr_en_d <= '1';
            clr_done_pulse <= '0';
        elsif rising_edge(i_clk_50) then
            clr_done_pulse <= '0';
            if (clr_en_d = '1' and s_clr_en = '0') then
                clr_done_pulse <= '1';
            end if;
            clr_en_d <= s_clr_en;
        end if;
    end process;

    --------------------------------------------------------------------
    -- ADXL345 (I2C)
    --------------------------------------------------------------------
    u_adxl : entity work.adxl345_i2c
        generic map ( g_clk_hz => 50_000_000 )
        port map (
            i_clk   => i_clk_50,
            i_rst_n => i_rst_n,
            io_scl  => io_adxl_scl,
            io_sda  => io_adxl_sda,
            o_ax    => s_ax,
            o_ay    => s_ay,
            o_ready => s_accel_ready
        );

    --------------------------------------------------------------------
    -- Latch accel_ok once ready ever goes high (fixes "ready pulse" issue)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            accel_ok <= '0';
        elsif rising_edge(i_clk_50) then
            if s_accel_ready = '1' then
                accel_ok <= '1';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- tick_acc ~30Hz
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
    -- Sample raw accel at 30Hz (stable inputs for game)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            ax_samp <= (others => '0');
            ay_samp <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if tick_acc = '1' and accel_ok = '1' then
                ax_samp <= s_ax;
                ay_samp <= s_ay;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Gain + deadband + saturation for GAME (this is the main fix)
    --------------------------------------------------------------------
    process(ax_samp, ay_samp)
        variable ax_tmp, ay_tmp : integer;
        variable ax_abs, ay_abs : integer;
    begin
        ax_tmp := to_integer(ax_samp);
        ay_tmp := to_integer(ay_samp);

        ax_abs := ax_tmp; if ax_abs < 0 then ax_abs := -ax_abs; end if;
        ay_abs := ay_tmp; if ay_abs < 0 then ay_abs := -ay_abs; end if;

        -- deadband
        if ax_abs < integer(DEAD_BAND) then ax_tmp := 0; end if;
        if ay_abs < integer(DEAD_BAND) then ay_tmp := 0; end if;

        -- gain (shift-left)
        ax_tmp := ax_tmp * (2 ** integer(GAIN_SHIFT));
        ay_tmp := ay_tmp * (2 ** integer(GAIN_SHIFT));

        -- saturation
        if ax_tmp >  integer(SAT_LIMIT) then ax_tmp :=  integer(SAT_LIMIT); end if;
        if ax_tmp < -integer(SAT_LIMIT) then ax_tmp := -integer(SAT_LIMIT); end if;
        if ay_tmp >  integer(SAT_LIMIT) then ay_tmp :=  integer(SAT_LIMIT); end if;
        if ay_tmp < -integer(SAT_LIMIT) then ay_tmp := -integer(SAT_LIMIT); end if;

        ax_game <= to_signed(ax_tmp, 16);
        ay_game <= to_signed(ay_tmp, 16);
    end process;

    ax_abs_u <= unsigned(abs(ax_samp));
    ay_abs_u <= unsigned(abs(ay_samp));

    --------------------------------------------------------------------
    -- Game reset during clear + pulse after clear
    --------------------------------------------------------------------
    s_greset_final <= s_greset_user or s_clr_en or clr_done_pulse;

    --------------------------------------------------------------------
    -- Game engine (USE scaled values + accel_ok)
    --------------------------------------------------------------------
    u_game : entity work.gravity_maze_engine
        generic map (
            h_res   => h_res,
            v_res   => v_res,
            fb_size => FB_SIZE,
            clk_hz  => 50_000_000
        )
        port map (
            i_clk         => i_clk_50,
            i_rst_n       => i_rst_n,
            i_pause       => '0',
            i_reset       => s_greset_final,
            i_ax          => ax_game,
            i_ay          => ay_game,
            i_accel_ready => accel_ok,
            o_we          => g_we,
            o_addr        => g_addr,
            o_data        => g_data,
            i_q           => s_fb_q_a
        );

    -- any_we latch
    process(i_clk_50, i_rst_n)
    begin
        if i_rst_n = '0' then
            any_we <= '0';
        elsif rising_edge(i_clk_50) then
            if g_we = '1' then
                any_we <= '1';
            end if;
        end if;
    end process;

    -- Port A mux: clear priority
    s_we_a   <= '1' when s_clr_en = '1' else g_we;
    s_addr_a <= s_clr_addr when s_clr_en = '1' else g_addr;

    s_data_a <= x"01" when (s_clr_en = '1' and (s_clr_addr mod 2 = 0)) else
                x"00" when (s_clr_en = '1') else
                g_data;

    -- DPRAM framebuffer
    u_fb : entity work.dpram
        generic map (
            mem_size   => FB_SIZE,
            data_width => 8
        )
        port map (
            i_clk_a  => i_clk_50,
            i_clk_b  => s_clk_27,
            i_data_a => s_data_a,
            i_data_b => (others => '0'),
            i_addr_a => s_addr_a,
            i_addr_b => s_rd_addr,
            i_we_a   => s_we_a,
            i_we_b   => '0',
            o_q_a    => s_fb_q_a,
            o_q_b    => s_fb_q_b
        );

    --------------------------------------------------------------------
    -- VIDEO OUTPUT (4 modes)
    -- 00 = game palette
    -- 01 = checkerboard
    -- 10 = ACCEL BARS (RAW sampled ax_samp/ay_samp) + RED if accel_ok=0
    -- 11 = stripes view (01 only)
    --------------------------------------------------------------------
    process(s_de, s_x_counter, s_y_counter, s_fb_q_b, debug_mode, ax_samp, ay_samp, accel_ok)
        variable axv, ayv : integer;
        variable ax_len   : integer;
        variable ay_len   : integer;
    begin
        if s_de = '1' then
            case debug_mode is

                when "01" =>
                    if (((s_x_counter/16) mod 2) = ((s_y_counter/16) mod 2)) then
                        o_hdmi_tx_d <= x"000000";
                    else
                        o_hdmi_tx_d <= x"FFFFFF";
                    end if;

                when "10" =>
                    if accel_ok = '0' then
                        o_hdmi_tx_d <= x"300000"; -- dark red background if not ready
                    else
                        -- ACCEL BARS: show AX (top) and AY (left)
                        axv := to_integer(ax_samp);
                        ayv := to_integer(ay_samp);

                        ax_len := axv / 16; -- more sensitive than /64
                        ay_len := ayv / 16;

                        if ax_len > 300 then ax_len := 300; end if;
                        if ax_len < -300 then ax_len := -300; end if;
                        if ay_len > 200 then ay_len := 200; end if;
                        if ay_len < -200 then ay_len := -200; end if;

                        o_hdmi_tx_d <= x"000000";

                        -- AX bar: y=20..30, center x=360
                        if (integer(s_y_counter) >= 20 and integer(s_y_counter) <= 30) then
                            if integer(s_x_counter) = 360 then
                                o_hdmi_tx_d <= x"FFFFFF";
                            end if;

                            if ax_len >= 0 then
                                if (integer(s_x_counter) >= 360 and integer(s_x_counter) <= 360 + ax_len) then
                                    o_hdmi_tx_d <= x"00FF00";
                                end if;
                            else
                                if (integer(s_x_counter) <= 360 and integer(s_x_counter) >= 360 + ax_len) then
                                    o_hdmi_tx_d <= x"FF0000";
                                end if;
                            end if;
                        end if;

                        -- AY bar: x=20..30, center y=240
                        if (integer(s_x_counter) >= 20 and integer(s_x_counter) <= 30) then
                            if integer(s_y_counter) = 240 then
                                o_hdmi_tx_d <= x"FFFFFF";
                            end if;

                            if ay_len >= 0 then
                                if (integer(s_y_counter) >= 240 and integer(s_y_counter) <= 240 + ay_len) then
                                    o_hdmi_tx_d <= x"0000FF";
                                end if;
                            else
                                if (integer(s_y_counter) <= 240 and integer(s_y_counter) >= 240 + ay_len) then
                                    o_hdmi_tx_d <= x"FFFF00";
                                end if;
                            end if;
                        end if;
                    end if;

                when "11" =>
                    if s_fb_q_b = x"01" then
                        o_hdmi_tx_d <= x"FFFFFF";
                    else
                        o_hdmi_tx_d <= x"000000";
                    end if;

                when others =>
							 case s_fb_q_b is
								  when x"00" => o_hdmi_tx_d <= x"000000"; -- empty
								  when x"01" => o_hdmi_tx_d <= x"FFFFFF"; -- wall / white
								  when x"02" => o_hdmi_tx_d <= x"00FF00"; -- ball / green
								  when x"03" => o_hdmi_tx_d <= x"FFFF00"; -- (legacy goal yellow, no longer used for drawing)
								  when x"04" => o_hdmi_tx_d <= x"8B004B"; -- ENSEA maroon (NEW)
								  when x"05" => o_hdmi_tx_d <= x"6A00FF"; -- toxic purple (hazard)
								  when others => o_hdmi_tx_d <= x"FF00FF";
							 end case;
            end case;

        else
            o_hdmi_tx_d <= x"000000";
        end if;
    end process;

    --------------------------------------------------------------------
    -- LEDs / diagnostics
    --------------------------------------------------------------------
    o_leds <= std_logic_vector(cnt_x);

    o_de10_leds(0) <= s_clr_en;
    o_de10_leds(1) <= any_we;
    o_de10_leds(2) <= accel_ok;     -- IMPORTANT: latched ready
    o_de10_leds(3) <= g_we;
    o_de10_leds(5 downto 4) <= std_logic_vector(debug_mode);
    o_de10_leds(6) <= tick_acc;     -- 30Hz tick
    o_de10_leds(7) <= pll_locked;

end architecture rtl;
