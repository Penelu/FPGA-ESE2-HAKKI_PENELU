library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adxl345_i2c is
    generic(
        g_clk_hz : natural := 50_000_000;
        g_i2c_hz : natural := 100_000
    );
    port(
        i_clk    : in  std_logic;
        i_rst_n  : in  std_logic;

        io_scl   : inout std_logic;
        io_sda   : inout std_logic;

        o_ax     : out signed(15 downto 0);
        o_ay     : out signed(15 downto 0);

        o_ready  : out std_logic
    );
end entity;

architecture rtl of adxl345_i2c is

    -- ADXL345 address (ALT=1 => 0x53)
    -- constant ADXL_ADDR7 : std_logic_vector(6 downto 0) := "1010011"; -- 0x53
	 constant ADXL_ADDR7 : std_logic_vector(6 downto 0) := "0011101"; -- 0x1D


    -- Registers
    constant REG_DEVID      : std_logic_vector(7 downto 0) := x"00";
    constant REG_BW_RATE    : std_logic_vector(7 downto 0) := x"2C";
    constant REG_POWER_CTL  : std_logic_vector(7 downto 0) := x"2D";
    constant REG_DATA_FORMAT: std_logic_vector(7 downto 0) := x"31";
    constant REG_DATAX0     : std_logic_vector(7 downto 0) := x"32";

    -- Values (datasheet-consistent)
    constant VAL_BW_RATE     : std_logic_vector(7 downto 0) := x"0A"; -- 100 Hz
    constant VAL_POWER_CTL   : std_logic_vector(7 downto 0) := x"08"; -- MEASURE=1
    constant VAL_DATA_FORMAT : std_logic_vector(7 downto 0) := x"08"; -- FULL_RES=1, +/-2g

    -- I2C quarter-period tick
    constant C_DIV : natural := g_clk_hz / (g_i2c_hz * 4);
    signal div_cnt : natural range 0 to C_DIV-1 := 0;
    signal tick    : std_logic := '0';

    -- Open-drain: oe='1' drives LOW, oe='0' releases (Z)
    signal scl_oe : std_logic := '0';
    signal sda_oe : std_logic := '0';

    function od(en : std_logic) return std_logic is
    begin
        if en = '1' then
            return '0';
        else
            return 'Z';
        end if;
    end function;

    signal sda_in : std_logic := '1';

    -- 20Hz update (slow enough to see)
    constant TREAD_DIV : natural := g_clk_hz / 20;
    signal tread_cnt : natural range 0 to TREAD_DIV-1 := 0;
    signal tick_read : std_logic := '0';

    -- Boot wait ~100ms
    constant TBOOT_DIV : natural := g_clk_hz / 10;
    signal tboot_cnt : natural range 0 to TBOOT_DIV-1 := 0;
    signal boot_done : std_logic := '0';

    type t_state is (
        ST_BOOT,

        -- INIT sequence:
        -- write DATA_FORMAT, BW_RATE, POWER_CTL
        ST_I_W_START, ST_I_W_ADDR, ST_I_W_REG, ST_I_W_VAL, ST_I_W_STOP,
        ST_I_NEXT,

        -- Optional: read DEVID once
        ST_ID_STARTW, ST_ID_ADDRW, ST_ID_REG, ST_ID_REPSTART, ST_ID_ADDRR,
        ST_ID_RX, ST_ID_STOP,

        -- Periodic read burst 6 bytes
        ST_R_STARTW, ST_R_ADDRW, ST_R_REG, ST_R_REPSTART, ST_R_ADDRR,
        ST_R_RX0, ST_R_RX1, ST_R_RX2, ST_R_RX3, ST_R_RX4, ST_R_RX5,
        ST_R_STOP,
        ST_IDLE
    );
    signal st : t_state := ST_BOOT;

    -- Which init register we are writing
    signal init_step : integer range 0 to 2 := 0;
    signal cur_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal cur_val   : std_logic_vector(7 downto 0) := (others => '0');

    -- Byte engine
    signal tx_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_i   : integer range 0 to 7 := 7;

    -- ACK sample: '0' means ACK, '1' means NACK
    signal ack_nack : std_logic := '1';

    -- RX storage
    signal b0,b1,b2,b3,b4,b5 : std_logic_vector(7 downto 0) := (others => '0');

    -- Ready flag
    signal ready_i : std_logic := '0';

    -- Low-level I2C sub-FSM states (embedded)
    type t_ll is (
        LL_NONE,

        LL_START_A, LL_START_B, LL_START_C,
        LL_STOP_A,  LL_STOP_B,  LL_STOP_C,

        LL_TX_SET, LL_TX_HIGH, LL_TX_LOW,
        LL_TX_ACK_REL, LL_TX_ACK_HIGH, LL_TX_ACK_LOW,

        LL_RX_REL, LL_RX_HIGH, LL_RX_LOW,
        LL_RX_ACK_SET, LL_RX_ACK_HIGH, LL_RX_ACK_LOW
    );
    signal ll : t_ll := LL_NONE;

    signal next_st : t_state := ST_IDLE;

    -- Helpers
    function addr_wr(a7 : std_logic_vector(6 downto 0)) return std_logic_vector is
    begin
        return a7 & '0';
    end function;

    function addr_rd(a7 : std_logic_vector(6 downto 0)) return std_logic_vector is
    begin
        return a7 & '1';
    end function;

    -- For RX: drive ACK=0 for first 5 bytes, NACK=1 for last byte
    signal rx_drive_ack0 : std_logic := '0';

begin

    io_scl <= od(scl_oe);
    io_sda <= od(sda_oe);

    o_ready <= ready_i;

    --------------------------------------------------------------------
    -- I2C quarter-tick
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            div_cnt <= 0;
            tick <= '0';
        elsif rising_edge(i_clk) then
            if div_cnt = C_DIV-1 then
                div_cnt <= 0;
                tick <= '1';
            else
                div_cnt <= div_cnt + 1;
                tick <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 20Hz read tick
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            tread_cnt <= 0;
            tick_read <= '0';
        elsif rising_edge(i_clk) then
            if tread_cnt = TREAD_DIV-1 then
                tread_cnt <= 0;
                tick_read <= '1';
            else
                tread_cnt <= tread_cnt + 1;
                tick_read <= '0';
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Boot wait ~100ms
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            tboot_cnt <= 0;
            boot_done <= '0';
        elsif rising_edge(i_clk) then
            if boot_done = '0' then
                if tboot_cnt = TBOOT_DIV-1 then
                    tboot_cnt <= 0;
                    boot_done <= '1';
                else
                    tboot_cnt <= tboot_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Main FSM + Low-level bitbang engine (NO "when/else" inside clocked logic)
    --------------------------------------------------------------------
    process(i_clk, i_rst_n)
        variable vbit : std_logic;
    begin
        if i_rst_n = '0' then
            st <= ST_BOOT;
            ll <= LL_NONE;

            scl_oe <= '0';
            sda_oe <= '0';
            sda_in <= '1';

            tx_byte <= (others => '0');
            rx_byte <= (others => '0');
            bit_i <= 7;
            ack_nack <= '1';

            init_step <= 0;
            cur_reg <= (others => '0');
            cur_val <= (others => '0');

            b0 <= (others => '0'); b1 <= (others => '0');
            b2 <= (others => '0'); b3 <= (others => '0');
            b4 <= (others => '0'); b5 <= (others => '0');

            o_ax <= (others => '0');
            o_ay <= (others => '0');

            ready_i <= '0';
            next_st <= ST_IDLE;
            rx_drive_ack0 <= '0';

        elsif rising_edge(i_clk) then
            sda_in <= io_sda;

            if tick = '1' then

                ----------------------------------------------------------------
                -- LOW-LEVEL I2C micro-steps (ll)
                -- Runs until it returns ll=LL_NONE; then high-level st continues.
                ----------------------------------------------------------------
                if ll /= LL_NONE then
                    case ll is

                        -- START: SDA goes low while SCL high, then pull SCL low
                        when LL_START_A =>
                            scl_oe <= '0';
                            sda_oe <= '0';
                            ll <= LL_START_B;

                        when LL_START_B =>
                            scl_oe <= '0';
                            sda_oe <= '1';      -- SDA low
                            ll <= LL_START_C;

                        when LL_START_C =>
                            scl_oe <= '1';      -- SCL low
                            -- keep SDA low
                            ll <= LL_NONE;
                            st <= next_st;

                        -- STOP: SDA low while SCL low, then release SCL high, then release SDA high
                        when LL_STOP_A =>
                            scl_oe <= '1';      -- SCL low
                            sda_oe <= '1';      -- SDA low
                            ll <= LL_STOP_B;

                        when LL_STOP_B =>
                            scl_oe <= '0';      -- SCL high
                            sda_oe <= '1';      -- keep SDA low
                            ll <= LL_STOP_C;

                        when LL_STOP_C =>
                            scl_oe <= '0';      -- SCL high
                            sda_oe <= '0';      -- SDA high => STOP
                            ll <= LL_NONE;
                            st <= next_st;

                        -- TX bit: set SDA while SCL low, then SCL high, then SCL low
                        when LL_TX_SET =>
                            scl_oe <= '1';      -- SCL low
                            vbit := tx_byte(bit_i);
                            if vbit = '0' then
                                sda_oe <= '1';  -- drive low
                            else
                                sda_oe <= '0';  -- release
                            end if;
                            ll <= LL_TX_HIGH;

                        when LL_TX_HIGH =>
                            scl_oe <= '0';      -- SCL high
                            ll <= LL_TX_LOW;

                        when LL_TX_LOW =>
                            scl_oe <= '1';      -- SCL low
                            if bit_i = 0 then
                                ll <= LL_TX_ACK_REL;
                            else
                                bit_i <= bit_i - 1;
                                ll <= LL_TX_SET;
                            end if;

                        -- TX ACK: release SDA, raise SCL and sample, then SCL low
                        when LL_TX_ACK_REL =>
                            scl_oe <= '1';      -- SCL low
                            sda_oe <= '0';      -- release for ACK bit
                            ll <= LL_TX_ACK_HIGH;

                        when LL_TX_ACK_HIGH =>
                            scl_oe <= '0';      -- SCL high
                            ack_nack <= sda_in; -- 0=ACK, 1=NACK
                            ll <= LL_TX_ACK_LOW;

                        when LL_TX_ACK_LOW =>
                            scl_oe <= '1';      -- SCL low
                            ll <= LL_NONE;
                            st <= next_st;

                        -- RX bit: release SDA, raise SCL sample, then SCL low
                        when LL_RX_REL =>
                            scl_oe <= '1';      -- SCL low
                            sda_oe <= '0';      -- release
                            ll <= LL_RX_HIGH;

                        when LL_RX_HIGH =>
                            scl_oe <= '0';      -- SCL high
                            rx_byte(bit_i) <= sda_in;
                            ll <= LL_RX_LOW;

                        when LL_RX_LOW =>
                            scl_oe <= '1';      -- SCL low
                            if bit_i = 0 then
                                ll <= LL_RX_ACK_SET;
                            else
                                bit_i <= bit_i - 1;
                                ll <= LL_RX_REL;
                            end if;

                        -- RX ACK/NACK: drive low for ACK=0 (rx_drive_ack0=1), release for NACK=1
                        when LL_RX_ACK_SET =>
                            scl_oe <= '1';      -- SCL low
                            if rx_drive_ack0 = '1' then
                                sda_oe <= '1';  -- ACK=0
                            else
                                sda_oe <= '0';  -- NACK=1
                            end if;
                            ll <= LL_RX_ACK_HIGH;

                        when LL_RX_ACK_HIGH =>
                            scl_oe <= '0';      -- SCL high
                            ll <= LL_RX_ACK_LOW;

                        when LL_RX_ACK_LOW =>
                            scl_oe <= '1';      -- SCL low
                            sda_oe <= '0';      -- release again
                            ll <= LL_NONE;
                            st <= next_st;

                        when others =>
                            ll <= LL_NONE;
                            st <= ST_IDLE;
                    end case;

                else
                    ----------------------------------------------------------------
                    -- HIGH-LEVEL ADXL345 FSM (only runs when ll=LL_NONE)
                    ----------------------------------------------------------------
                    case st is

                        when ST_BOOT =>
                            scl_oe <= '0';
                            sda_oe <= '0';
                            ready_i <= '0';
                            if boot_done = '1' then
                                init_step <= 0;
                                st <= ST_I_W_START;
                            end if;

                        -- Choose init register/value
                        when ST_I_W_START =>
                            if init_step = 0 then
                                cur_reg <= REG_DATA_FORMAT;
                                cur_val <= VAL_DATA_FORMAT;
                            elsif init_step = 1 then
                                cur_reg <= REG_BW_RATE;
                                cur_val <= VAL_BW_RATE;
                            else
                                cur_reg <= REG_POWER_CTL;
                                cur_val <= VAL_POWER_CTL;
                            end if;

                            -- START
                            next_st <= ST_I_W_ADDR;
                            ll <= LL_START_A;

                        when ST_I_W_ADDR =>
                            -- TX: addrW
                            tx_byte <= addr_wr(ADXL_ADDR7);
                            bit_i <= 7;
                            next_st <= ST_I_W_REG;
                            ll <= LL_TX_SET;

                        when ST_I_W_REG =>
                            -- if NACK, retry same step
                            if ack_nack = '1' then
                                next_st <= ST_I_W_STOP;
                                ll <= LL_STOP_A;
                            else
                                tx_byte <= cur_reg;
                                bit_i <= 7;
                                next_st <= ST_I_W_VAL;
                                ll <= LL_TX_SET;
                            end if;

                        when ST_I_W_VAL =>
                            if ack_nack = '1' then
                                next_st <= ST_I_W_STOP;
                                ll <= LL_STOP_A;
                            else
                                tx_byte <= cur_val;
                                bit_i <= 7;
                                next_st <= ST_I_W_STOP;
                                ll <= LL_TX_SET;
                            end if;

                        when ST_I_W_STOP =>
                            -- STOP after sending value (even if NACK)
                            next_st <= ST_I_NEXT;
                            ll <= LL_STOP_A;

                        when ST_I_NEXT =>
                            -- if last ACK was NACK at any point, just redo same step
                            if ack_nack = '1' then
                                st <= ST_I_W_START;
                            else
                                if init_step = 2 then
                                    -- optional: read DEVID once
                                    st <= ST_ID_STARTW;
                                else
                                    init_step <= init_step + 1;
                                    st <= ST_I_W_START;
                                end if;
                            end if;

                        ----------------------------------------------------------------
                        -- Read DEVID (0x00) once to confirm comms
                        -- START, addrW, reg, REPSTART, addrR, RX, STOP
                        ----------------------------------------------------------------
                        when ST_ID_STARTW =>
                            next_st <= ST_ID_ADDRW;
                            ll <= LL_START_A;

                        when ST_ID_ADDRW =>
                            tx_byte <= addr_wr(ADXL_ADDR7);
                            bit_i <= 7;
                            next_st <= ST_ID_REG;
                            ll <= LL_TX_SET;

                        when ST_ID_REG =>
                            if ack_nack = '1' then
                                next_st <= ST_ID_STOP;
                                ll <= LL_STOP_A;
                            else
                                tx_byte <= REG_DEVID;
                                bit_i <= 7;
                                next_st <= ST_ID_REPSTART;
                                ll <= LL_TX_SET;
                            end if;

                        when ST_ID_REPSTART =>
                            next_st <= ST_ID_ADDRR;
                            ll <= LL_START_A; -- repeated start is same sequence

                        when ST_ID_ADDRR =>
                            tx_byte <= addr_rd(ADXL_ADDR7);
                            bit_i <= 7;
                            next_st <= ST_ID_RX;
                            ll <= LL_TX_SET;

                        when ST_ID_RX =>
                            if ack_nack = '1' then
                                next_st <= ST_ID_STOP;
                                ll <= LL_STOP_A;
                            else
                                rx_byte <= (others => '0');
                                bit_i <= 7;
                                rx_drive_ack0 <= '0';  -- NACK after single byte
                                next_st <= ST_ID_STOP;
                                ll <= LL_RX_REL;
                            end if;

                        when ST_ID_STOP =>
                            next_st <= ST_IDLE;
                            ll <= LL_STOP_A;
                            -- If you want to gate ready on DEVID==E5 you can add it here.
                            ready_i <= '1';

                        ----------------------------------------------------------------
                        -- IDLE -> periodic burst read
                        ----------------------------------------------------------------
                        when ST_IDLE =>
                            scl_oe <= '0';
                            sda_oe <= '0';
                            if ready_i = '1' and tick_read = '1' then
                                st <= ST_R_STARTW;
                            end if;

                        when ST_R_STARTW =>
                            next_st <= ST_R_ADDRW;
                            ll <= LL_START_A;

                        when ST_R_ADDRW =>
                            tx_byte <= addr_wr(ADXL_ADDR7);
                            bit_i <= 7;
                            next_st <= ST_R_REG;
                            ll <= LL_TX_SET;

                        when ST_R_REG =>
                            if ack_nack = '1' then
                                next_st <= ST_R_STOP;
                                ll <= LL_STOP_A;
                            else
                                tx_byte <= REG_DATAX0; -- 0x32
                                bit_i <= 7;
                                next_st <= ST_R_REPSTART;
                                ll <= LL_TX_SET;
                            end if;

                        when ST_R_REPSTART =>
                            next_st <= ST_R_ADDRR;
                            ll <= LL_START_A;

                        when ST_R_ADDRR =>
                            tx_byte <= addr_rd(ADXL_ADDR7);
                            bit_i <= 7;
                            next_st <= ST_R_RX0;
                            ll <= LL_TX_SET;

                        -- RX 6 bytes with ACK for first 5, NACK for last
                        when ST_R_RX0 =>
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '1'; -- ACK
                            next_st <= ST_R_RX1;
                            ll <= LL_RX_REL;

                        when ST_R_RX1 =>
                            b0 <= rx_byte;
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '1'; -- ACK
                            next_st <= ST_R_RX2;
                            ll <= LL_RX_REL;

                        when ST_R_RX2 =>
                            b1 <= rx_byte;
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '1'; -- ACK
                            next_st <= ST_R_RX3;
                            ll <= LL_RX_REL;

                        when ST_R_RX3 =>
                            b2 <= rx_byte;
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '1'; -- ACK
                            next_st <= ST_R_RX4;
                            ll <= LL_RX_REL;

                        when ST_R_RX4 =>
                            b3 <= rx_byte;
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '1'; -- ACK
                            next_st <= ST_R_RX5;
                            ll <= LL_RX_REL;

                        when ST_R_RX5 =>
                            b4 <= rx_byte;
                            rx_byte <= (others => '0');
                            bit_i <= 7;
                            rx_drive_ack0 <= '0'; -- NACK on last
                            next_st <= ST_R_STOP;
                            ll <= LL_RX_REL;

                        when ST_R_STOP =>
                            -- last byte captured now
                            b5 <= rx_byte;

                            -- STOP
                            next_st <= ST_IDLE;
                            ll <= LL_STOP_A;

                            -- Update outputs (little-endian)
                            o_ax <= signed(b1 & b0);
                            o_ay <= signed(b3 & b2);

                        when others =>
                            st <= ST_IDLE;

                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture;
