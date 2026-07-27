library ieee;
use ieee.std_logic_1164.all;

entity vhd_dff is
  port (clk : in  std_logic;
        d   : in  std_logic;
        q   : out std_logic);
end entity;

architecture rtl of vhd_dff is
  signal q_r : std_logic;
begin
  process (clk)
  begin
    if rising_edge(clk) then
      q_r <= d;
    end if;
  end process;
  q <= q_r;
end architecture;
