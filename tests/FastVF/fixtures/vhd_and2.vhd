library ieee;
use ieee.std_logic_1164.all;

entity vhd_and2 is
  port (a : in  std_logic;
        b : in  std_logic;
        y : out std_logic);
end entity;

architecture rtl of vhd_and2 is
begin
  y <= a and b;
end architecture;
