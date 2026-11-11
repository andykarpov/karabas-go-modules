-- tb_eq_island_encoder: the island encoder of zhdmi (rtl: the packets in flip-flops) against its
-- original (ref/, island_encoder_ref: the packets in an array, which XST made LUTRAM of). A behavioural
-- ghdl run (ghdl --synth turns the array of the original into a RAM with a registered read, which is
-- not what XST builds). Packets of 31 random bytes with gaps of 0..63 clocks, dvalid also low now and
-- then and held by dready; every output is compared on every clock.
-- Prints "tb_eq_island_encoder: N errors".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_eq_island_encoder is
end tb_eq_island_encoder;

architecture sim of tb_eq_island_encoder is
	signal clk : std_logic := '0';
	signal done : boolean := false;  -- stops the clock, so the run ends
	signal reset : std_logic := '1';
	signal data : std_logic_vector(7 downto 0) := (others => '0');
	signal dvalid : std_logic := '0';
	signal r_rdy, r_busy, r_pre, r_grd, r_pkt, r_a0 : std_logic;
	signal n_rdy, n_busy, n_pre, n_grd, n_pkt, n_a0 : std_logic;
	signal r_a1, r_a2, n_a1, n_a2 : std_logic_vector(3 downto 0);
	constant CLOCKS : integer := 60000;
begin
	clk <= not clk after 5 ns when not done;

	ref_enc : entity work.island_encoder_ref port map (clk, reset, data, dvalid, r_rdy, r_busy, r_pre, r_grd,
		r_pkt, r_a0, r_a1, r_a2);
	new_enc : entity work.island_encoder port map (clk, reset, data, dvalid, n_rdy, n_busy, n_pre, n_grd,
		n_pkt, n_a0, n_a1, n_a2);

	process
		variable s1, s2 : positive := 11;
		variable rnd : real;
		variable errors, packets, left, gap : integer := 0;
	begin
		wait for 42 ns;
		reset <= '0';
		for c in 0 to CLOCKS - 1 loop
			wait until rising_edge(clk);
			if r_rdy /= n_rdy or r_busy /= n_busy or r_pre /= n_pre or r_grd /= n_grd or r_pkt /= n_pkt or
			   r_a0 /= n_a0 or r_a1 /= n_a1 or r_a2 /= n_a2 then
				if errors < 5 then
					report "ERROR at clock " & integer'image(c);
				end if;
				errors := errors + 1;
			end if;
			if dvalid = '1' and r_rdy = '1' then
				left := left - 1;
			end if;
			if left = 0 and dvalid = '0' then
				if gap = 0 then
					left := 31;
					packets := packets + 1;
					uniform(s1, s2, rnd);
					gap := integer(trunc(rnd * 64.0));
				else
					gap := gap - 1;
				end if;
			end if;
			uniform(s1, s2, rnd);
			if left /= 0 and rnd < 0.75 then dvalid <= '1'; else dvalid <= '0'; end if;
			uniform(s1, s2, rnd);
			data <= std_logic_vector(to_unsigned(integer(trunc(rnd * 256.0)), 8));
		end loop;
		report "tb_eq_island_encoder: " & integer'image(errors) & " errors (" & integer'image(packets) & " packets)";
		done <= true;
		wait;
	end process;
end sim;
