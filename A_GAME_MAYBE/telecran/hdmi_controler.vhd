library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdmi_controler is
    generic (
        h_res  : natural := 720;
        v_res  : natural := 480;
        h_sync : natural := 61;
        h_fp   : natural := 58;
        h_bp   : natural := 18;
        v_sync : natural := 5;
        v_fp   : natural := 30;
        v_bp   : natural := 9
    );
    port (
        i_clk   : in  std_logic;
        i_rst_n : in  std_logic;

        o_hdmi_hs : out std_logic;
        o_hdmi_vs : out std_logic;
        o_hdmi_de : out std_logic;

        o_x_counter : out natural range 0 to h_res-1;
        o_y_counter : out natural range 0 to v_res-1;

        o_pixel_en      : out std_logic;
        o_pixel_address : out natural
    );
end entity;

architecture rtl of hdmi_controler is
    constant H_TOTAL : natural := h_res + h_fp + h_sync + h_bp;
    constant V_TOTAL : natural := v_res + v_fp + v_sync + v_bp;

    signal h_cnt : natural range 0 to H_TOTAL-1 := 0;
    signal v_cnt : natural range 0 to V_TOTAL-1 := 0;

    signal de_i  : std_logic := '0';
begin
    process(i_clk, i_rst_n)
    begin
        if i_rst_n = '0' then
            h_cnt <= 0;
            v_cnt <= 0;
        elsif rising_edge(i_clk) then
            if h_cnt = H_TOTAL-1 then
                h_cnt <= 0;
                if v_cnt = V_TOTAL-1 then
                    v_cnt <= 0;
                else
                    v_cnt <= v_cnt + 1;
                end if;
            else
                h_cnt <= h_cnt + 1;
            end if;
        end if;
    end process;

    de_i      <= '1' when (h_cnt < h_res and v_cnt < v_res) else '0';
    o_hdmi_de <= de_i;

    -- active-low syncs (common for HDMI timing blocks)
    o_hdmi_hs <= '0'
        when (h_cnt >= h_res + h_fp and h_cnt < h_res + h_fp + h_sync)
        else '1';

    o_hdmi_vs <= '0'
        when (v_cnt >= v_res + v_fp and v_cnt < v_res + v_fp + v_sync)
        else '1';

    -- counters in active area, else clamp to 0
    o_x_counter <= h_cnt when (h_cnt < h_res) else 0;
    o_y_counter <= v_cnt when (v_cnt < v_res) else 0;

    o_pixel_en <= de_i;

    -- framebuffer address (valid in active region)
    o_pixel_address <= (v_cnt * h_res + h_cnt) when de_i = '1' else 0;
end architecture;
