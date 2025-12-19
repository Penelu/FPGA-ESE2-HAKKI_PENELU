library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master_simple is
    generic(
        g_clk_hz : natural := 50_000_000;
        g_i2c_hz : natural := 100_000
    );
    port(
        i_clk    : in  std_logic;
        i_rst_n  : in  std_logic;

        i_start  : in  std_logic;                     -- pulse
        i_rw     : in  std_logic;                     -- '0' write, '1' read
        i_addr7  : in  std_logic_vector(6 downto 0);
        i_wdata  : in  std_logic_vector(7 downto 0);

        o_rdata  : out std_logic_vector(7 downto 0);
        o_busy   : out std_logic;
        o_done   : out std_logic;
        o_ackerr : out std_logic;

        io_scl   : inout std_logic;
        io_sda   : inout std_logic
    );
end entity;

architecture rtl of i2c_master_simple is
    constant C_DIV : natural := g_clk_hz / (g_i2c_hz * 4);
    signal div_cnt : natural range 0 to C_DIV-1 := 0;
    signal tick    : std_logic := '0';

    -- Open-drain enables: '1' drives LOW, '0' releases (Z)
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

    type t_state is (
        IDLE,
        START_0, START_1,
        SEND_BYTE_0, SEND_BYTE_1, SEND_BYTE_2,
        RECV_BYTE_0, RECV_BYTE_1, RECV_BYTE_2,
        STOP_0, STOP_1,
        DONE
    );
    signal st : t_state := IDLE;

    signal sh : std_logic_vector(7 downto 0) := (others => '0');
    signal rd : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_i : integer range 0 to 7 := 7;

    signal ackerr_i     : std_logic := '0';
    signal phase_is_ack : std_logic := '0';
    signal sda_sample   : std_logic := '1';

begin
    io_scl <= od(scl_oe);
    io_sda <= od(sda_oe);

    o_rdata  <= rd;
    o_ackerr <= ackerr_i;
    o_busy   <= '1' when (st /= IDLE and st /= DONE) else '0';
    o_done   <= '1' when (st = DONE) else '0';

    -- tick generator
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

    -- I2C FSM
    process(i_clk, i_rst_n)
        variable sda_in : std_logic;
    begin
        if i_rst_n = '0' then
            st <= IDLE;
            scl_oe <= '0';
            sda_oe <= '0';
            sh <= (others => '0');
            rd <= (others => '0');
            bit_i <= 7;
            ackerr_i <= '0';
            phase_is_ack <= '0';
            sda_sample <= '1';

        elsif rising_edge(i_clk) then
            sda_in := io_sda;

            if tick = '1' then
                case st is
                    when IDLE =>
                        scl_oe <= '0';
                        sda_oe <= '0';
                        ackerr_i <= '0';
                        phase_is_ack <= '0';
                        if i_start = '1' then
                            st <= START_0;
                        end if;

                    -- START: SDA low while SCL high
                    when START_0 =>
                        scl_oe <= '0'; -- release SCL
                        sda_oe <= '1'; -- drive SDA low
                        st <= START_1;

                    -- Pull SCL low, load address+rw
                    when START_1 =>
                        scl_oe <= '1'; -- SCL low
                        sda_oe <= '1'; -- keep SDA low
                        sh <= i_addr7 & i_rw;
                        bit_i <= 7;
                        phase_is_ack <= '0';
                        st <= SEND_BYTE_0;

                    -- SEND: SCL low, set SDA bit (or release for ACK)
                    when SEND_BYTE_0 =>
                        scl_oe <= '1'; -- SCL low
                        if phase_is_ack = '0' then
                            -- send data bit: 0->drive low, 1->release
                            if sh(bit_i) = '0' then
                                sda_oe <= '1';
                            else
                                sda_oe <= '0';
                            end if;
                        else
                            -- ACK bit: release SDA
                            sda_oe <= '0';
                        end if;
                        st <= SEND_BYTE_1;

                    -- SEND: SCL high, sample SDA
                    when SEND_BYTE_1 =>
                        scl_oe <= '0'; -- SCL high
                        sda_sample <= sda_in;
                        st <= SEND_BYTE_2;

                    -- SEND: SCL low, advance or process ACK
                    when SEND_BYTE_2 =>
                        scl_oe <= '1'; -- SCL low

                        if phase_is_ack = '1' then
                            -- ACK=0, NACK=1
                            if sda_sample = '1' then
                                ackerr_i <= '1';
                                st <= STOP_0;
                            else
                                -- ACK OK -> decide next
                                if (i_rw = '0') and (sh = (i_addr7 & i_rw)) then
                                    -- address ACK -> send data byte
                                    sh <= i_wdata;
                                    bit_i <= 7;
                                    phase_is_ack <= '0';
                                    st <= SEND_BYTE_0;

                                elsif (i_rw = '1') and (sh = (i_addr7 & i_rw)) then
                                    -- address ACK for read -> receive 1 byte
                                    bit_i <= 7;
                                    st <= RECV_BYTE_0;

                                else
                                    -- data ACK (write) -> stop
                                    st <= STOP_0;
                                end if;
                            end if;

                        else
                            -- normal data bit
                            if bit_i = 0 then
                                phase_is_ack <= '1'; -- next is ACK phase
                            else
                                bit_i <= bit_i - 1;
                            end if;
                            st <= SEND_BYTE_0;
                        end if;

                    -- RECEIVE: SCL low, release SDA
                    when RECV_BYTE_0 =>
                        scl_oe <= '1'; -- SCL low
                        sda_oe <= '0'; -- release SDA
                        st <= RECV_BYTE_1;

                    -- RECEIVE: SCL high, sample bit
                    when RECV_BYTE_1 =>
                        scl_oe <= '0'; -- SCL high
                        rd(bit_i) <= sda_in;
                        st <= RECV_BYTE_2;

                    -- RECEIVE: SCL low, advance
                    when RECV_BYTE_2 =>
                        scl_oe <= '1'; -- SCL low
                        if bit_i = 0 then
                            st <= STOP_0;
                        else
                            bit_i <= bit_i - 1;
                            st <= RECV_BYTE_0;
                        end if;

                    -- STOP: hold SDA low while SCL low
                    when STOP_0 =>
                        scl_oe <= '1'; -- SCL low
                        sda_oe <= '1'; -- SDA low
                        st <= STOP_1;

                    -- STOP: release SCL then SDA
                    when STOP_1 =>
                        scl_oe <= '0'; -- SCL high
                        sda_oe <= '0'; -- SDA high
                        st <= DONE;

                    when DONE =>
                        st <= IDLE;

                    when others =>
                        st <= IDLE;
                end case;
            end if;
        end if;
    end process;

end architecture;
