library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library pll;
use pll.all;

entity telecran is
    port (
        -- FPGA
        i_clk_50 : in std_logic;

        -- HDMI
        io_hdmi_i2c_scl : inout std_logic;
        io_hdmi_i2c_sda : inout std_logic;
        o_hdmi_tx_clk   : out std_logic;
        o_hdmi_tx_d     : out std_logic_vector(23 downto 0);
        o_hdmi_tx_de    : out std_logic;
        o_hdmi_tx_hs    : out std_logic;
        i_hdmi_tx_int   : in  std_logic;
        o_hdmi_tx_vs    : out std_logic;

        -- KEYs
        i_rst_n : in std_logic;

        -- LEDs
        o_leds      : out std_logic_vector(9 downto 0);
        o_de10_leds : out std_logic_vector(7 downto 0);

        -- Coder
        i_left_ch_a  : in std_logic;
        i_left_ch_b  : in std_logic;
        i_left_pb    : in std_logic;
        i_right_ch_a : in std_logic;
        i_right_ch_b : in std_logic;
        i_right_pb   : in std_logic
    );
end entity telecran;

architecture rtl of telecran is

    --------------------------------------------------------------------
    -- HDMI I2C config + PLL
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- Resolution (must match hdmi_controler)
    --------------------------------------------------------------------
    constant h_res : natural := 720;
    constant v_res : natural := 480;

    --------------------------------------------------------------------
    -- PLL outputs
    --------------------------------------------------------------------
    signal s_clk_27   : std_logic;
    signal pll_locked : std_logic;
    signal s_rst_n    : std_logic;

    --------------------------------------------------------------------
    -- HDMI controller outputs
    --------------------------------------------------------------------
    signal s_hs        : std_logic;
    signal s_vs        : std_logic;
    signal s_de        : std_logic;
    signal s_x_counter : natural range 0 to h_res-1;
    signal s_y_counter : natural range 0 to v_res-1;

    --------------------------------------------------------------------
    -- Encoder LEFT (X)
    --------------------------------------------------------------------
    signal a_d1, a_d2 : std_logic := '0';
    signal b_d1, b_d2 : std_logic := '0';
    signal a_rise, a_fall : std_logic;
    signal b_rise, b_fall : std_logic;

    signal cnt_x : unsigned(9 downto 0) := (others => '0'); -- 0..1023

    --------------------------------------------------------------------
    -- Encoder RIGHT (Y)
    --------------------------------------------------------------------
    signal ra_d1, ra_d2 : std_logic := '0';
    signal rb_d1, rb_d2 : std_logic := '0';
    signal ra_rise, ra_fall : std_logic;
    signal rb_rise, rb_fall : std_logic;

    signal cnt_y : unsigned(8 downto 0) := (others => '0'); -- 0..511

    --------------------------------------------------------------------
    -- Encoder sampling enable (~1 ms @ 50 MHz)
    --------------------------------------------------------------------
    signal enc_enable : std_logic := '0';

    --------------------------------------------------------------------
    -- Pixel position (clamped to 720x480)
    --------------------------------------------------------------------
    signal s_x_pos : natural range 0 to h_res-1 := 0;
    signal s_y_pos : natural range 0 to v_res-1 := 0;

    --------------------------------------------------------------------
    -- Framebuffer RAM (dpram)
    --------------------------------------------------------------------
    constant FB_SIZE : natural := h_res * v_res; -- 345600

    signal s_wr_addr : natural range 0 to FB_SIZE-1;
    signal s_rd_addr : natural range 0 to FB_SIZE-1;

    signal s_fb_q_a : std_logic_vector(7 downto 0);
    signal s_fb_q_b : std_logic_vector(7 downto 0);

    -- Draw enable
    signal s_draw_we : std_logic := '0';

    -- Clear framebuffer
    signal s_clr_en   : std_logic := '1';
    signal s_clr_addr : natural range 0 to FB_SIZE-1 := 0;

    -- Port A mux (clear has priority over draw)
    signal s_we_a   : std_logic;
    signal s_addr_a : natural range 0 to FB_SIZE-1;
    signal s_data_a : std_logic_vector(7 downto 0);

    -- Erase button edge detect (on left push button)
    signal left_pb_d : std_logic := '1';
    signal erase_req : std_logic := '0';

begin

    --------------------------------------------------------------------
    -- Edge detection (LEFT)
    --------------------------------------------------------------------
    a_rise <= '1' when (a_d1 = '1' and a_d2 = '0') else '0';
    a_fall <= '1' when (a_d1 = '0' and a_d2 = '1') else '0';

    b_rise <= '1' when (b_d1 = '1' and b_d2 = '0') else '0';
    b_fall <= '1' when (b_d1 = '0' and b_d2 = '1') else '0';

    --------------------------------------------------------------------
    -- Edge detection (RIGHT)
    --------------------------------------------------------------------
    ra_rise <= '1' when (ra_d1 = '1' and ra_d2 = '0') else '0';
    ra_fall <= '1' when (ra_d1 = '0' and ra_d2 = '1') else '0';

    rb_rise <= '1' when (rb_d1 = '1' and rb_d2 = '0') else '0';
    rb_fall <= '1' when (rb_d1 = '0' and rb_d2 = '1') else '0';

    --------------------------------------------------------------------
    -- enc_enable ~1ms @ 50 MHz
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- LEFT encoder (X)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if (i_rst_n = '0') then
            a_d1 <= '0'; a_d2 <= '0';
            b_d1 <= '0'; b_d2 <= '0';
            cnt_x <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if (enc_enable = '1') then
                a_d1 <= i_left_ch_a;
                a_d2 <= a_d1;
                b_d1 <= i_left_ch_b;
                b_d2 <= b_d1;

                if ((a_rise = '1' and b_d1 = '0') or (a_fall = '1' and b_d1 = '1')) then
                    cnt_x <= cnt_x + 1;
                elsif ((b_rise = '1' and a_d1 = '0') or (b_fall = '1' and a_d1 = '1')) then
                    cnt_x <= cnt_x - 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- RIGHT encoder (Y)
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if (i_rst_n = '0') then
            ra_d1 <= '0'; ra_d2 <= '0';
            rb_d1 <= '0'; rb_d2 <= '0';
            cnt_y <= (others => '0');
        elsif rising_edge(i_clk_50) then
            if (enc_enable = '1') then
                ra_d1 <= i_right_ch_a;
                ra_d2 <= ra_d1;
                rb_d1 <= i_right_ch_b;
                rb_d2 <= rb_d1;

                if ((ra_rise = '1' and rb_d1 = '0') or (ra_fall = '1' and rb_d1 = '1')) then
                    cnt_y <= cnt_y + 1;
                elsif ((rb_rise = '1' and ra_d1 = '0') or (rb_fall = '1' and ra_d1 = '1')) then
                    cnt_y <= cnt_y - 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Detect erase request (falling edge on left push button)
    -- NOTE: this assumes active-low pushbutton. If yours is active-high,
    -- change the edge condition accordingly.
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if (i_rst_n = '0') then
            left_pb_d <= '1';
            erase_req <= '0';
        elsif rising_edge(i_clk_50) then
            left_pb_d <= i_left_pb;

            -- falling edge detection
            if (left_pb_d = '1' and i_left_pb = '0') then
                erase_req <= '1';
            else
                erase_req <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- PLL
    --------------------------------------------------------------------
    pll0 : component pll
        port map (
            refclk    => i_clk_50,
            rst       => not(i_rst_n),
            outclk_0  => s_clk_27,
            locked    => pll_locked
        );

    s_rst_n <= i_rst_n and pll_locked;

    --------------------------------------------------------------------
    -- HDMI I2C config (ADV7513)
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
    -- HDMI timing generator
    --------------------------------------------------------------------
    u_hdmi_ctrl : entity work.hdmi_controler
        generic map (
            h_res  => h_res,
            v_res  => v_res,
            h_sync => 61,
            h_fp   => 58,
            h_bp   => 18,
            v_sync => 5,
            v_fp   => 30,
            v_bp   => 9
        )
        port map (
            i_clk   => s_clk_27,
            i_rst_n => s_rst_n,

            o_hdmi_hs => s_hs,
            o_hdmi_vs => s_vs,
            o_hdmi_de => s_de,

            o_x_counter => s_x_counter,
            o_y_counter => s_y_counter,

            o_pixel_en      => open,
            o_pixel_address => open
        );

    --------------------------------------------------------------------
    -- HDMI outputs
    --------------------------------------------------------------------
    o_hdmi_tx_clk <= s_clk_27;
    o_hdmi_tx_hs  <= s_hs;
    o_hdmi_tx_vs  <= s_vs;
    o_hdmi_tx_de  <= s_de;

    --------------------------------------------------------------------
    -- Clamp encoder counters into valid pixel coordinates (720x480)
    --------------------------------------------------------------------
    process(cnt_x, cnt_y)
        variable vx : natural;
        variable vy : natural;
    begin
        vx := to_integer(cnt_x);
        vy := to_integer(cnt_y);

        if (vx >= h_res) then
            s_x_pos <= h_res - 1;
        else
            s_x_pos <= vx;
        end if;

        if (vy >= v_res) then
            s_y_pos <= v_res - 1;
        else
            s_y_pos <= vy;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Framebuffer addresses
    --------------------------------------------------------------------
    s_wr_addr <= s_y_pos * h_res + s_x_pos;
    s_rd_addr <= s_y_counter * h_res + s_x_counter;

    --------------------------------------------------------------------
    -- DRAW enable:
    -- Here we use RIGHT pushbutton for drawing, and LEFT pushbutton for erasing.
    -- If you want draw with both, it will conflict with erase button usage.
    --------------------------------------------------------------------
    s_draw_we <= i_right_pb;

    --------------------------------------------------------------------
    -- Clear framebuffer: startup OR erase button
    --------------------------------------------------------------------
    process(i_clk_50, i_rst_n)
    begin
        if (i_rst_n = '0') then
            s_clr_en   <= '1';
            s_clr_addr <= 0;

        elsif rising_edge(i_clk_50) then

            -- Start erase on button press
            if (erase_req = '1') then
                s_clr_en   <= '1';
                s_clr_addr <= 0;
            end if;

            -- Run clear sequence
            if (s_clr_en = '1') then
                if (s_clr_addr = FB_SIZE - 1) then
                    s_clr_en <= '0';
                else
                    s_clr_addr <= s_clr_addr + 1;
                end if;
            end if;

        end if;
    end process;

    --------------------------------------------------------------------
    -- Port A mux: clear has priority over draw
    --------------------------------------------------------------------
    s_we_a   <= '1'  when (s_clr_en = '1') else s_draw_we;
    s_addr_a <= s_clr_addr when (s_clr_en = '1') else s_wr_addr;
    s_data_a <= x"00" when (s_clr_en = '1') else x"FF";

    --------------------------------------------------------------------
    -- Dual-port RAM instantiation (dpram.vhd)
    --------------------------------------------------------------------
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
    -- VIDEO: display framebuffer
    --------------------------------------------------------------------
    process(s_de, s_fb_q_b)
    begin
        if (s_de = '1') then
            if (s_fb_q_b /= x"00") then
                o_hdmi_tx_d <= x"FFFFFF";
            else
                o_hdmi_tx_d <= x"000000";
            end if;
        else
            o_hdmi_tx_d <= x"000000";
        end if;
    end process;

    --------------------------------------------------------------------
    -- LEDs
    --------------------------------------------------------------------
    o_leds      <= std_logic_vector(cnt_x);
    o_de10_leds <= (others => '0');

end architecture rtl;
