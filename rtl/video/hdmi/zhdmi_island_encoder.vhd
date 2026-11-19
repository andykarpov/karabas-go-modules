-- zhdmi_island_encoder.vhd - HDMI data island encoder

-- Copyright (c) 2021-2025 Francois Galea <fgalea at free.fr>
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity island_encoder is
	-- karabas: ECC_LAG 1 takes the BCH ECC of a bit one clock later, from the registered aux outputs (the bit
	-- of the clock before), and only the clock that sends the first ECC bit adds the last data bit to it: a
	-- clock then has the bit mux or the ECC steps, not both (the mux and two ECC steps missed 65 MHz, agon
	-- 1024x768 on Mini G: -1.6 ns). The outputs are the same, clock by clock; 0 = as before.
	generic (
		ECC_LAG : integer := 0
	);
	port (
		clk      : in std_logic;
		reset    : in std_logic;

		data     : in std_logic_vector(7 downto 0);
		dvalid   : in std_logic;
		dready   : out std_logic;

		busy     : out std_logic;
		preamble : out std_logic;
		guard    : out std_logic;
		packet   : out std_logic;
		aux0     : out std_logic;
		aux1     : out std_logic_vector(3 downto 0);
		aux2     : out std_logic_vector(3 downto 0)
	);
end island_encoder;

architecture rtl of island_encoder is

	-- Data island packet
	type data_packet_t is array (0 to 30) of std_logic_vector(7 downto 0);
	-- packet double buffer
	-- karabas: the two packets: the bits are read at nine places with indexes that change every clock; as a
	-- RAM (XST splits an array of the two into two RAMs, an attribute on the array does not reach them)
	-- XST made LUTRAM copies (504 LUTs) and 900 LUTs of bit muxes. In flip-flops the reads are muxes
	-- (the packet is still written while it goes out, as before)
	signal packet_buffer0, packet_buffer1 : data_packet_t;
	attribute ram_extract : string;
	attribute ram_extract of packet_buffer0 : signal is "no";
	attribute ram_extract of packet_buffer1 : signal is "no";
	-- read packet index

	signal packet_rd_buf_idx : integer range 0 to 1;
	signal packet_rd_idx : integer range 0 to 30;
	-- packet buffer read state
	signal packet_available : std_logic;
	signal buffer_full : std_logic;

	signal packet_wr_buf_idx : integer range 0 to 1;

	-- state counter for infoframe data island generation
	signal ifcnt     : unsigned(4 downto 0);
	signal ecc0      : std_logic_vector(7 downto 0);
	type chn_ecc_t is array(0 to 3) of std_logic_vector(7 downto 0);
	signal ecc       : chn_ecc_t;

	type island_st_t is (idle, preamb, ld_guard, pack, tr_guard);
	signal island_st : island_st_t;

	signal s_busy     : std_logic;
	signal s_preamble : std_logic;
	signal s_guard    : std_logic;
	signal s_packet   : std_logic;
	-- karabas: the aux outputs as registers inside (ECC_LAG reads them)
	signal r_aux0 : std_logic;
	signal r_aux1, r_aux2 : std_logic_vector(3 downto 0);

	function next_ecc(old_ecc : in std_logic_vector; x : in std_logic) return std_logic_vector is
	begin
		return ('0' & old_ecc(7 downto 1)) xor (x"83" and (7 downto 0 => (x xor old_ecc(0))));
	end function;


begin

	s_busy <= '1' when island_st /= idle else '0';
	s_preamble <= '1' when island_st = preamb else '0';
	s_guard <= '1' when island_st = ld_guard or island_st = tr_guard else '0';
	s_packet <= '1' when island_st = pack else '0';
	aux0 <= r_aux0;
	aux1 <= r_aux1;
	aux2 <= r_aux2;

	buffer_full <= '1' when packet_rd_buf_idx /= packet_wr_buf_idx and packet_rd_idx = 30 else '0';
	dready <= '1' when dvalid = '1' and buffer_full = '0' else '0';

process(clk)
begin
	if rising_edge(clk) then
		busy <= s_busy;
		preamble <= s_preamble;
		guard <= s_guard;
		packet <= s_packet;
	end if;
end process;

-- Read input data
process(clk)
begin
	if rising_edge(clk) then
		if reset = '1' then
			packet_rd_buf_idx <= 0;
			packet_rd_idx <= 0;
		else
			if dvalid = '1' and buffer_full = '0' then
				-- dready is set (combinatorial)
				if packet_rd_buf_idx = 0 then
					packet_buffer0(packet_rd_idx) <= data;
				else
					packet_buffer1(packet_rd_idx) <= data;
				end if;
				if packet_rd_idx < 30 then
					packet_rd_idx <= packet_rd_idx + 1;
				else
					packet_rd_idx <= 0;
					packet_rd_buf_idx <= 1-packet_rd_buf_idx;
				end if;
			end if;
		end if;
	end if;
end process;

-- BCH encoder auxiliary data
process(clk)
	variable pck : data_packet_t;
	variable bid : integer range 0 to 7;
	variable idx : integer range 0 to 30;
	variable ec  : std_logic_vector(7 downto 0);
	variable b   : std_logic;
	variable e0  : std_logic_vector(7 downto 0);
begin
	if rising_edge(clk) then
		if reset = '1' then
			packet_wr_buf_idx <= 0;
			ifcnt <= (others => '0');
			island_st <= idle;
			r_aux0 <= '0';
			r_aux1 <= "0000";
			r_aux2 <= "0000";
		else
			if ifcnt > 0 then
				ifcnt <= ifcnt - 1;
			end if;

			case island_st is
			when idle =>
				if packet_rd_idx = 15 then
					ifcnt <= to_unsigned(7,ifcnt'length);
					island_st <= preamb;
				end if;
			when preamb =>
				if ifcnt = 0 then
					ifcnt <= to_unsigned(1,ifcnt'length);
					island_st <= ld_guard;
				end if;
			when ld_guard =>
				if ifcnt = 0 then
					ifcnt <= to_unsigned(31,ifcnt'length);
					ecc0 <= x"00";
					ecc <= (others => x"00");
					island_st <= pack;
				end if;
			when pack =>
				if packet_wr_buf_idx = 0 then
					pck := packet_buffer0;
				else
					pck := packet_buffer1;
				end if;
				bid := 7 - to_integer(ifcnt(2 downto 0));
				if ECC_LAG = 0 then
					if ifcnt >= 8 then
						idx := 3 - to_integer(ifcnt(4 downto 3));
						b := pck(idx)(bid);
						r_aux0 <= b;
						ecc0 <= next_ecc(ecc0,b);
					else
						r_aux0 <= ecc0(bid);
					end if;
				else
					-- karabas: the bit of the clock before (aux0) into ecc0 now (none before ifcnt 31)
					if ifcnt >= 8 then
						idx := 3 - to_integer(ifcnt(4 downto 3));
						r_aux0 <= pck(idx)(bid);
						if ifcnt /= 31 then
							ecc0 <= next_ecc(ecc0,r_aux0);
						end if;
					elsif ifcnt = 7 then
						e0 := next_ecc(ecc0,r_aux0);
						r_aux0 <= e0(bid);
						ecc0 <= e0;
					else
						r_aux0 <= ecc0(bid);
					end if;
				end if;

				bid := 6 - 2 * to_integer(ifcnt(1 downto 0));
				idx := 3 + 7 - to_integer(ifcnt(4 downto 2));
				if ECC_LAG = 0 then
					if ifcnt >= 4 then
						for i in 0 to 3 loop
							b := pck(idx+7*i)(bid);
							r_aux1(i) <= b;
							ec := next_ecc(ecc(i),b);
							b := pck(idx+7*i)(bid+1);
							r_aux2(i) <= b;
							ecc(i) <= next_ecc(ec,b);
						end loop;
					else
						for i in 0 to 3 loop
							r_aux1(i) <= ecc(i)(bid);
							r_aux2(i) <= ecc(i)(bid+1);
						end loop;
					end if;
				else
					-- karabas: the two bits of the clock before (aux1 / aux2) into ecc now
					for i in 0 to 3 loop
						ec := next_ecc(ecc(i),r_aux1(i));
						ec := next_ecc(ec,r_aux2(i));
						if ifcnt >= 4 then
							r_aux1(i) <= pck(idx+7*i)(bid);
							r_aux2(i) <= pck(idx+7*i)(bid+1);
							if ifcnt /= 31 then
								ecc(i) <= ec;
							end if;
						elsif ifcnt = 3 then
							r_aux1(i) <= ec(bid);
							r_aux2(i) <= ec(bid+1);
							ecc(i) <= ec;
						else
							r_aux1(i) <= ecc(i)(bid);
							r_aux2(i) <= ecc(i)(bid+1);
						end if;
					end loop;
				end if;

				if ifcnt = 0 then
					packet_wr_buf_idx <= 1-packet_wr_buf_idx;
					if packet_wr_buf_idx /= packet_rd_buf_idx and packet_rd_idx = 0 then
						-- buffer is empty - end of data island
						ifcnt <= to_unsigned(1,ifcnt'length);
						island_st <= tr_guard;
					else
						-- send another packet
						ifcnt <= to_unsigned(31,ifcnt'length);
						ecc0 <= x"00";
						ecc <= (others => x"00");
					end if;
				end if;
			when tr_guard =>
				r_aux0 <= '0';
				r_aux1 <= "0000";
				r_aux2 <= "0000";
				if ifcnt = 0 then
					island_st <= idle;
				end if;
			end case;
		end if;
	end if;
end process;



end architecture;
