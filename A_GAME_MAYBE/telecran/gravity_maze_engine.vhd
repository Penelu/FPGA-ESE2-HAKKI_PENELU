library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gravity_maze_engine is
    generic (
        h_res   : natural := 720;
        v_res   : natural := 480;
        fb_size : natural := 720 * 480;
        clk_hz  : natural := 50_000_000
    );
    port (
        i_clk         : in  std_logic;
        i_rst_n       : in  std_logic;

        i_pause       : in  std_logic;
        i_reset       : in  std_logic;

        i_ax          : in  signed(15 downto 0);
        i_ay          : in  signed(15 downto 0);
        i_accel_ready : in  std_logic;

        o_we    : out std_logic;
        o_addr  : out natural range 0 to fb_size-1;
        o_data  : out std_logic_vector(7 downto 0);

        i_q     : in  std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of gravity_maze_engine is

    --------------------------------------------------------------------
    -- Pixel codes (8-bit framebuffer)
    --------------------------------------------------------------------
    constant PIX_EMPTY    : std_logic_vector(7 downto 0) := x"00"; -- black
    constant PIX_WALL     : std_logic_vector(7 downto 0) := x"01"; -- white
    constant PIX_BALL     : std_logic_vector(7 downto 0) := x"02"; -- green
    constant PIX_GOAL_BG  : std_logic_vector(7 downto 0) := x"04"; -- maroon
    constant PIX_GOAL_FG  : std_logic_vector(7 downto 0) := x"01"; -- white
    constant PIX_HAZARD   : std_logic_vector(7 downto 0) := x"05"; -- purple (add in telecran palette)

    constant BALL_R : integer := 2;

    --------------------------------------------------------------------
    -- Fixed goal rectangle (logo is fixed 61x51)
    --------------------------------------------------------------------
    constant GOAL_X0 : integer := 640;
    constant GOAL_Y0 : integer :=  60;
    constant GOAL_X1 : integer := 700; -- 61px
    constant GOAL_Y1 : integer := 110; -- 51px

    --------------------------------------------------------------------
    -- Logo ROM (61x51)
    --------------------------------------------------------------------
    constant LOGO_W : integer := 61;
    constant LOGO_H : integer := 51;

    type t_logo_rows is array (0 to LOGO_H-1) of std_logic_vector(LOGO_W-1 downto 0);

    constant C_LOGO : t_logo_rows := (
        0  => "0000000000000000000000000000000000000000000000000000000000000",
        1  => "0000000000000000000000000000000000000000000000000000000000000",
        2  => "0000000000000000000000000000000000000000000000000000000000000",
        3  => "0000000000000000000000000000000000000000000000000000000000000",
        4  => "0000000000000000000000000000000000000000000000000000000000000",
        5  => "0000000000000000000000000000000000000000000000000000000000000",
        6  => "0000000000000000000000000000000000000000000000000000000000000",
        7  => "0000000000000000000000000000000000000000000000000000000000000",
        8  => "0000000000111111111111111111111111110000000000000000000000000",
        9  => "0000000000111111111111111111111111110000000000000000000000000",
        10 => "0000000000111111111111111111111111110000000000000000000000000",
        11 => "0000000000111111111111111111111111110000000000000000000000000",
        12 => "0000000000111111111111111111111111110000000000000000000000000",
        13 => "0000000000111111100000000000000000000000000000000000000000000",
        14 => "0000000000111111100000000000000000000000000000000000000000000",
        15 => "0000000000111111100000000000000000000000000000000000000000000",
        16 => "0000000000111111100000000000000000000000000000000000000000000",
        17 => "0000000000111111100000000000000000000000000000000000000000000",
        18 => "0000000000111111100000000000000000000000000000000000000000000",
        19 => "0000000000111111100000000000000000000000000000000000000000000",
        20 => "0000000000111111100000000000000000000000000000000000000000000",
        21 => "0000000000111111100000000000000000000000000000000000000000000",
        22 => "0000000000111111100000000000000000000000000000000000000000000",
        23 => "0000000000111111111111111111111111110000000000000000000000000",
        24 => "0000000000111111111111111111111111110000000000000000000000000",
        25 => "0000000000111111111111111111111111110000000000000000000000000",
        26 => "0000000000111111111111111111111111110000000000000000000000000",
        27 => "0000000000111111111111111111111111110000000000000000000000000",
        28 => "0000000000111111100000000000000000000000000000000000000000000",
        29 => "0000000000111111100000000000000000000000000000000000000000000",
        30 => "0000000000111111100000000000000000000000000000000000000000000",
        31 => "0000000000111111100000000000000000000000000000000000000000000",
        32 => "0000000000111111100000000000000000000000000000000000000000000",
        33 => "0000000000111111100000000000000000000000000000000000000000000",
        34 => "0000000000111111100000000000000000000000000000000000000000000",
        35 => "0000000000111111100000000000000000000000000000000000000000000",
        36 => "0000000000111111100000000000000000000000000000000000000000000",
        37 => "0000000000111111100000000000000000000000000000000000000000000",
        38 => "0000000000111111111111111111111111110000000000000000000000000",
        39 => "0000000000111111111111111111111111110000000000000000000000000",
        40 => "0000000000111111111111111111111111110000000000000000000000000",
        41 => "0000000000111111111111111111111111110000000000000000000000000",
        42 => "0000000000111111111111111111111111110000000000000000000000000",
        43 => "0000000000000000000000000000000000000000000000000000000000000",
        44 => "0000000000000000000000000000000000000000000000000000000000000",
        45 => "0000000000000000000000000000000000000000000000000000000000000",
        46 => "0000000000000000000000000000000000000000000000000000000000000",
        47 => "0000000000000000000000000000000000000000000000000000000000000",
        48 => "0000000000000000000000000000000000000000000000000000000000000",
        49 => "0000000000000000000000000000000000000000000000000000000000000",
        50 => "0000000000000000000000000000000000000000000000000000000000000"
    );

    --------------------------------------------------------------------
    -- Timing
    --------------------------------------------------------------------
    constant TICK_HZ  : natural := 25;
    constant TICK_DIV : natural := clk_hz / TICK_HZ;

    constant SEC_DIV  : natural := clk_hz;

    --------------------------------------------------------------------
    -- Physics tuning
    --------------------------------------------------------------------
    constant ACC_DIV_BASE : integer := 256;
    constant DEAD         : integer := 32;
    constant VMAX_BASE    : integer := 6;

    --------------------------------------------------------------------
    -- Random walls (rectangles)
    --------------------------------------------------------------------
    constant MAX_WALLS : integer := 20;

    type t_rect is record
        x0 : integer;
        x1 : integer;
        y0 : integer;
        y1 : integer;
    end record;

    type t_rects is array (0 to MAX_WALLS-1) of t_rect;

    signal walls    : t_rects;
    signal n_walls  : integer range 0 to MAX_WALLS := 0;

    -- Hazard rectangle
    signal hz_x0, hz_x1, hz_y0, hz_y1 : integer := 300;

    -- LFSR for pseudo-random
    signal lfsr : unsigned(15 downto 0) := x"ACE1";

    --------------------------------------------------------------------
    -- State machine
    --------------------------------------------------------------------
    type state_t is (
        S_LEVEL_GEN,
        S_INIT_DRAW,
        S_RUN_IDLE,
        S_ERASE_BALL,
        S_DRAW_BALL,

        S_WIN_MSG_DRAW,
        S_WIN_MSG_WAIT,

        S_LOSE_MSG_DRAW,
        S_LOSE_MSG_WAIT,

        S_QUIT_MSG_DRAW,
        S_QUIT_MSG_WAIT
    );

    signal st : state_t := S_LEVEL_GEN;

    signal init_addr : natural range 0 to fb_size-1 := 0;

    signal tick_cnt  : natural range 0 to TICK_DIV-1 := 0;
    signal tick      : std_logic := '0';

    signal sec_cnt   : natural range 0 to SEC_DIV-1 := 0;
    signal sec_tick  : std_logic := '0';

    signal wait_s    : natural range 0 to 15 := 0;

    signal bx, by    : integer := 40;
    signal bxp, byp  : integer := 40;
    signal vx, vy    : integer := 0;

    signal level     : natural range 1 to 999 := 1;

    signal dx, dy    : integer range -BALL_R to BALL_R := -BALL_R;

    signal we_r      : std_logic := '0';
    signal addr_r    : natural range 0 to fb_size-1 := 0;
    signal data_r    : std_logic_vector(7 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Helpers (PURE)
    --------------------------------------------------------------------
    function to_addr(x, y : integer) return natural is
        variable a : integer;
    begin
        a := y * integer(h_res) + x;
        if a < 0 then
            return 0;
        elsif a > integer(fb_size-1) then
            return fb_size-1;
        else
            return natural(a);
        end if;
    end function;

    function clamp(v, lo, hi : integer) return integer is
    begin
        if v < lo then return lo;
        elsif v > hi then return hi;
        else return v;
        end if;
    end function;

    function in_rect(x, y, x0, x1, y0, y1 : integer) return boolean is
    begin
        return (x >= x0 and x <= x1 and y >= y0 and y <= y1);
    end function;

    function in_goal(x, y : integer) return boolean is
    begin
        return in_rect(x, y, GOAL_X0, GOAL_X1, GOAL_Y0, GOAL_Y1);
    end function;

    function hit_rect(ball_x, ball_y, rx0, rx1, ry0, ry1 : integer) return boolean is
        variable bx0, bx1, by0, by1 : integer;
    begin
        bx0 := ball_x - BALL_R; bx1 := ball_x + BALL_R;
        by0 := ball_y - BALL_R; by1 := ball_y + BALL_R;

        return (bx0 <= rx1) and (bx1 >= rx0) and (by0 <= ry1) and (by1 >= ry0);
    end function;

    --------------------------------------------------------------------
    -- Walls (IMPURE: reads signals)
    --------------------------------------------------------------------
    impure function is_wall_level(x, y : integer) return boolean is
        variable i : integer;
    begin
        for i in 0 to MAX_WALLS-1 loop
            if i < n_walls then
                if in_rect(x, y, walls(i).x0, walls(i).x1, walls(i).y0, walls(i).y1) then
                    return true;
                end if;
            end if;
        end loop;
        return false;
    end function;

    impure function is_wall(x, y : integer) return boolean is
    begin
        if (x <= 10) or (x >= integer(h_res)-11) or (y <= 10) or (y >= integer(v_res)-11) then
            return true;
        end if;

        if is_wall_level(x, y) then
            return true;
        end if;

        return false;
    end function;

    --------------------------------------------------------------------
    -- 5x7 font
    --------------------------------------------------------------------
    function glyph_row(c : character; r : integer) return std_logic_vector is
        variable v : std_logic_vector(4 downto 0) := "00000";
    begin
        case c is
            when 'A' =>
                case r is
                    when 0 => v := "01110";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "11111";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "10001";
                end case;
            when 'C' =>
                case r is
                    when 0 => v := "01110";
                    when 1 => v := "10001";
                    when 2 => v := "10000";
                    when 3 => v := "10000";
                    when 4 => v := "10000";
                    when 5 => v := "10001";
                    when others => v := "01110";
                end case;
            when 'D' =>
                case r is
                    when 0 => v := "11110";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "10001";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "11110";
                end case;
            when 'E' =>
                case r is
                    when 0 => v := "11111";
                    when 1 => v := "10000";
                    when 2 => v := "10000";
                    when 3 => v := "11110";
                    when 4 => v := "10000";
                    when 5 => v := "10000";
                    when others => v := "11111";
                end case;
            when 'H' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "11111";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "10001";
                end case;
            when 'I' =>
                case r is
                    when 0 => v := "11111";
                    when 1 => v := "00100";
                    when 2 => v := "00100";
                    when 3 => v := "00100";
                    when 4 => v := "00100";
                    when 5 => v := "00100";
                    when others => v := "11111";
                end case;
            when 'K' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "10010";
                    when 2 => v := "10100";
                    when 3 => v := "11000";
                    when 4 => v := "10100";
                    when 5 => v := "10010";
                    when others => v := "10001";
                end case;
            when 'L' =>
                case r is
                    when 0 => v := "10000";
                    when 1 => v := "10000";
                    when 2 => v := "10000";
                    when 3 => v := "10000";
                    when 4 => v := "10000";
                    when 5 => v := "10000";
                    when others => v := "11111";
                end case;
            when 'M' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "11011";
                    when 2 => v := "10101";
                    when 3 => v := "10101";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "10001";
                end case;
            when 'N' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "11001";
                    when 2 => v := "10101";
                    when 3 => v := "10011";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "10001";
                end case;
            when 'O' =>
                case r is
                    when 0 => v := "01110";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "10001";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "01110";
                end case;
            when 'Q' =>
                case r is
                    when 0 => v := "01110";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "10001";
                    when 4 => v := "10101";
                    when 5 => v := "10010";
                    when others => v := "01101";
                end case;
            when 'R' =>
                case r is
                    when 0 => v := "11110";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "11110";
                    when 4 => v := "10100";
                    when 5 => v := "10010";
                    when others => v := "10001";
                end case;
            when 'S' =>
                case r is
                    when 0 => v := "01111";
                    when 1 => v := "10000";
                    when 2 => v := "10000";
                    when 3 => v := "01110";
                    when 4 => v := "00001";
                    when 5 => v := "00001";
                    when others => v := "11110";
                end case;
            when 'T' =>
                case r is
                    when 0 => v := "11111";
                    when 1 => v := "00100";
                    when 2 => v := "00100";
                    when 3 => v := "00100";
                    when 4 => v := "00100";
                    when 5 => v := "00100";
                    when others => v := "00100";
                end case;
            when 'U' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "10001";
                    when 4 => v := "10001";
                    when 5 => v := "10001";
                    when others => v := "01110";
                end case;
            when 'W' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "10001";
                    when 2 => v := "10001";
                    when 3 => v := "10101";
                    when 4 => v := "10101";
                    when 5 => v := "11011";
                    when others => v := "10001";
                end case;
            when 'X' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "01010";
                    when 2 => v := "00100";
                    when 3 => v := "00100";
                    when 4 => v := "00100";
                    when 5 => v := "01010";
                    when others => v := "10001";
                end case;
            when 'Y' =>
                case r is
                    when 0 => v := "10001";
                    when 1 => v := "01010";
                    when 2 => v := "00100";
                    when 3 => v := "00100";
                    when 4 => v := "00100";
                    when 5 => v := "00100";
                    when others => v := "00100";
                end case;
            when '1' =>
                case r is
                    when 0 => v := "00100";
                    when 1 => v := "01100";
                    when 2 => v := "00100";
                    when 3 => v := "00100";
                    when 4 => v := "00100";
                    when 5 => v := "00100";
                    when others => v := "01110";
                end case;
            when ' ' =>
                v := "00000";
            when others =>
                v := "00000";
        end case;
        return v;
    end function;

    function msg_pixel(msg : string; x, y : integer; x0, y0 : integer) return boolean is
        variable cx   : integer;
        variable cy   : integer;
        variable idx  : integer;
        variable col  : integer;
        variable row  : integer;
        variable g    : std_logic_vector(4 downto 0);
    begin
        cx := x - x0;
        cy := y - y0;

        if (cx < 0) or (cy < 0) then return false; end if;

        row := cy;
        if row < 0 or row > 6 then return false; end if;

        idx := cx / 6;
        col := cx mod 6;

        if col = 5 then return false; end if;
        if idx < 0 or idx >= msg'length then return false; end if;

        g := glyph_row(msg(msg'low + idx), row);
        return (g(4 - col) = '1');
    end function;

begin
    o_we   <= we_r;
    o_addr <= addr_r;
    o_data <= data_r;

    --------------------------------------------------------------------
    -- 25 Hz tick
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            tick_cnt <= 0;
            tick     <= '0';
        elsif rising_edge(i_clk) then
            if tick_cnt = TICK_DIV-1 then
                tick_cnt <= 0;
                tick     <= '1';
            else
                tick_cnt <= tick_cnt + 1;
                tick     <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 1 second tick
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            sec_cnt  <= 0;
            sec_tick <= '0';
        elsif rising_edge(i_clk) then
            if sec_cnt = SEC_DIV-1 then
                sec_cnt  <= 0;
                sec_tick <= '1';
            else
                sec_cnt  <= sec_cnt + 1;
                sec_tick <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Main FSM
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
        variable x, y : integer;
        variable ax_i, ay_i : integer;
        variable ax_s, ay_s : integer;
        variable nx, ny : integer;
        variable nvx, nvy : integer;
        variable px, py : integer;

        variable acc_div : integer;
        variable vmax    : integer;

        variable i : integer;
        variable w, h : integer;
        variable x0, y0 : integer;
        variable thick : integer;
        variable want_walls : integer;

        constant MSG_WIN1 : string := "YOU SUCCEEDED ENSEAS 1ST YEAR";
        constant MSG_WIN2 : string := "IM SURE YOU WONT SUCCEED THE NEXT ONE";
        constant MSG_LOSE : string := "YOU LOSE ENSEA WON";
        constant MSG_QUIT : string := "I KNEW YOU ARE A QUITTER";
    begin
        if i_rst_n = '0' then
            st        <= S_LEVEL_GEN;
            init_addr <= 0;

            level   <= 1;
            n_walls <= 0;

            bx <= 40; by <= 40;
            bxp <= 40; byp <= 40;
            vx <= 0; vy <= 0;

            dx <= -BALL_R;
            dy <= -BALL_R;

            we_r   <= '0';
            addr_r <= 0;
            data_r <= PIX_EMPTY;

            wait_s <= 0;
            lfsr   <= x"ACE1";

            hz_x0 <= 300; hz_x1 <= 340; hz_y0 <= 220; hz_y1 <= 260;

        elsif rising_edge(i_clk) then
            we_r <= '0';

            if i_reset = '1' and st /= S_QUIT_MSG_DRAW and st /= S_QUIT_MSG_WAIT then
                st        <= S_QUIT_MSG_DRAW;
                init_addr <= 0;
                wait_s    <= 10;

            else
                case st is

                    when S_LEVEL_GEN =>
                        want_walls := 6 + integer(level);
                        if want_walls > MAX_WALLS then want_walls := MAX_WALLS; end if;
                        n_walls <= want_walls;

                        thick := 8 + (integer(level) / 2);
                        if thick > 18 then thick := 18; end if;

                        lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));

                        for i in 0 to MAX_WALLS-1 loop
                            if i < want_walls then
                                x0 := 40 + to_integer((lfsr + to_unsigned(i*97, 16)) mod to_unsigned(620, 16));
										  y0 := 40 + to_integer((lfsr + to_unsigned(i*53, 16)) mod to_unsigned(380, 16));

                                if (lfsr(0) = '1') then
                                    w := 180 + to_integer((lfsr(7 downto 1)) mod 160);
                                    h := thick;
                                else
                                    w := thick;
                                    h := 140 + to_integer((lfsr(7 downto 1)) mod 160);
                                end if;

                                if x0 + w > 690 then x0 := 690 - w; end if;
                                if y0 + h > 470 then y0 := 470 - h; end if;

                                walls(i).x0 <= x0;
                                walls(i).x1 <= x0 + w;
                                walls(i).y0 <= y0;
                                walls(i).y1 <= y0 + h;
                            else
                                walls(i).x0 <= 0; walls(i).x1 <= -1; walls(i).y0 <= 0; walls(i).y1 <= -1;
                            end if;
                        end loop;

                        hz_x0 <= 320 + (integer(level) * 7) mod 120;
                        hz_y0 <= 210 + (integer(level) * 11) mod 80;
                        hz_x1 <= (320 + (integer(level) * 7) mod 120) + 40;
                        hz_y1 <= (210 + (integer(level) * 11) mod 80) + 40;

                        bx <= 40; by <= 40;
                        bxp <= 40; byp <= 40;
                        vx <= 0; vy <= 0;
                        dx <= -BALL_R; dy <= -BALL_R;

                        init_addr <= 0;
                        st <= S_INIT_DRAW;

                    when S_INIT_DRAW =>
                        x := integer(init_addr mod h_res);
                        y := integer(init_addr / h_res);

                        we_r   <= '1';
                        addr_r <= init_addr;

                        if in_goal(x, y) then
                            if C_LOGO(y - GOAL_Y0)(LOGO_W-1 - (x - GOAL_X0)) = '1' then
                                data_r <= PIX_GOAL_FG;
                            else
                                data_r <= PIX_GOAL_BG;
                            end if;

                        elsif in_rect(x, y, hz_x0, hz_x1, hz_y0, hz_y1) then
                            data_r <= PIX_HAZARD;

                        elsif is_wall(x, y) then
                            data_r <= PIX_WALL;
                        else
                            data_r <= PIX_EMPTY;
                        end if;

                        if init_addr = fb_size-1 then
                            dx <= -BALL_R;
                            dy <= -BALL_R;
                            st <= S_DRAW_BALL;
                        else
                            init_addr <= init_addr + 1;
                        end if;

                    when S_RUN_IDLE =>
                        if i_pause = '1' then
                            null;

                        elsif tick = '1' and i_accel_ready = '1' then
                            acc_div := ACC_DIV_BASE - integer(level);
                            if acc_div < 160 then acc_div := 160; end if;

                            vmax := VMAX_BASE + integer(level/2);
                            if vmax > 12 then vmax := 12; end if;

                            bxp <= bx;
                            byp <= by;

                            ax_i := to_integer(i_ax);
                            ay_i := to_integer(i_ay);

                            if ax_i > DEAD then ax_s := (ax_i - DEAD);
                            elsif ax_i < -DEAD then ax_s := (ax_i + DEAD);
                            else ax_s := 0;
                            end if;

                            if ay_i > DEAD then ay_s := (ay_i - DEAD);
                            elsif ay_i < -DEAD then ay_s := (ay_i + DEAD);
                            else ay_s := 0;
                            end if;

                            nvx := vx + (ax_s / acc_div);
                            nvy := vy - (ay_s / acc_div);

                            nvx := clamp(nvx, -vmax, vmax);
                            nvy := clamp(nvy, -vmax, vmax);

                            nvx := (nvx * 15) / 16;
                            nvy := (nvy * 15) / 16;

                            nx := bx + nvx;
                            ny := by + nvy;

                            if is_wall(nx, by) then nvx := 0; nx := bx; end if;
                            if is_wall(bx, ny) then nvy := 0; ny := by; end if;

                            if nx < 12 then nx := 12; end if;
                            if nx > integer(h_res)-13 then nx := integer(h_res)-13; end if;
                            if ny < 12 then ny := 12; end if;
                            if ny > integer(v_res)-13 then ny := integer(v_res)-13; end if;

                            vx <= nvx; vy <= nvy;
                            bx <= nx;  by <= ny;

                            if hit_rect(nx, ny, hz_x0, hz_x1, hz_y0, hz_y1) then
                                st        <= S_LOSE_MSG_DRAW;
                                init_addr <= 0;
                                wait_s    <= 10;

                            elsif hit_rect(nx, ny, GOAL_X0, GOAL_X1, GOAL_Y0, GOAL_Y1) then
                                st        <= S_WIN_MSG_DRAW;
                                init_addr <= 0;
                                wait_s    <= 5;

                            else
                                dx <= -BALL_R;
                                dy <= -BALL_R;
                                st <= S_ERASE_BALL;
                            end if;
                        end if;

                    when S_ERASE_BALL =>
                        px := bxp + dx;
                        py := byp + dy;

                        if (px >= 0 and px < integer(h_res) and py >= 0 and py < integer(v_res)) then
                            if (not is_wall(px, py)) and (not in_goal(px, py)) and
                               (not in_rect(px, py, hz_x0, hz_x1, hz_y0, hz_y1)) then
                                we_r   <= '1';
                                addr_r <= to_addr(px, py);
                                data_r <= PIX_EMPTY;
                            end if;
                        end if;

                        if dx = BALL_R then
                            dx <= -BALL_R;
                            if dy = BALL_R then
                                dy <= -BALL_R;
                                st <= S_DRAW_BALL;
                            else
                                dy <= dy + 1;
                            end if;
                        else
                            dx <= dx + 1;
                        end if;

                    when S_DRAW_BALL =>
                        px := bx + dx;
                        py := by + dy;

                        if (px >= 0 and px < integer(h_res) and py >= 0 and py < integer(v_res)) then
                            if (not is_wall(px, py)) and (not in_goal(px, py)) and
                               (not in_rect(px, py, hz_x0, hz_x1, hz_y0, hz_y1)) then
                                we_r   <= '1';
                                addr_r <= to_addr(px, py);
                                data_r <= PIX_BALL;
                            end if;
                        end if;

                        if dx = BALL_R then
                            dx <= -BALL_R;
                            if dy = BALL_R then
                                dy <= -BALL_R;
                                st <= S_RUN_IDLE;
                            else
                                dy <= dy + 1;
                            end if;
                        else
                            dx <= dx + 1;
                        end if;

                    when S_WIN_MSG_DRAW =>
                        x := integer(init_addr mod h_res);
                        y := integer(init_addr / h_res);

                        we_r   <= '1';
                        addr_r <= init_addr;

                        data_r <= PIX_GOAL_BG;

                        if msg_pixel(MSG_WIN1, x, y, 60, 180) then
                            data_r <= PIX_WALL;
                        elsif msg_pixel(MSG_WIN2, x, y, 60, 210) then
                            data_r <= PIX_WALL;
                        end if;

                        if init_addr = fb_size-1 then
                            st <= S_WIN_MSG_WAIT;
                        else
                            init_addr <= init_addr + 1;
                        end if;

                    when S_WIN_MSG_WAIT =>
                        if sec_tick = '1' then
                            if wait_s = 0 then
                                level <= level + 1;
                                st <= S_LEVEL_GEN;
                            else
                                wait_s <= wait_s - 1;
                            end if;
                        end if;

                    when S_LOSE_MSG_DRAW =>
                        x := integer(init_addr mod h_res);
                        y := integer(init_addr / h_res);

                        we_r   <= '1';
                        addr_r <= init_addr;

                        data_r <= PIX_HAZARD;

                        if msg_pixel(MSG_LOSE, x, y, 170, 210) then
                            data_r <= PIX_WALL;
                        end if;

                        if init_addr = fb_size-1 then
                            st <= S_LOSE_MSG_WAIT;
                        else
                            init_addr <= init_addr + 1;
                        end if;

                    when S_LOSE_MSG_WAIT =>
                        if sec_tick = '1' then
                            if wait_s = 0 then
                                level <= 1;
                                st <= S_LEVEL_GEN;
                            else
                                wait_s <= wait_s - 1;
                            end if;
                        end if;

                    when S_QUIT_MSG_DRAW =>
                        x := integer(init_addr mod h_res);
                        y := integer(init_addr / h_res);

                        we_r   <= '1';
                        addr_r <= init_addr;

                        data_r <= PIX_EMPTY;

                        if msg_pixel(MSG_QUIT, x, y, 140, 210) then
                            data_r <= PIX_WALL;
                        end if;

                        if init_addr = fb_size-1 then
                            st <= S_QUIT_MSG_WAIT;
                        else
                            init_addr <= init_addr + 1;
                        end if;

                    when S_QUIT_MSG_WAIT =>
                        if sec_tick = '1' then
                            if wait_s = 0 then
                                level <= 1;
                                st <= S_LEVEL_GEN;
                            else
                                wait_s <= wait_s - 1;
                            end if;
                        end if;

                    when others =>
                        st <= S_LEVEL_GEN;

                end case;
            end if;
        end if;
    end process;

end architecture;
