# CPS+ RTL — testbench driver.
#
#   make trigger    generate vectors from Phase-0/2 artifacts + packs,
#                   compile tb_trigger with Icarus Verilog, run all suites
#                   (CPS2 / CPS1.5 QSound-latch sniffer)
#   make cps1       generate vectors from the sf2 Phase-0 latch trace,
#                   compile tb_cps1_tap, run all suites (CPS1 byte latch)
#   make clean      remove generated work products
#
# Generated outputs live under cpsplus/work/ (untracked, per AGENTS.md).
# The player TB has its own driver (tb/Makefile.player, separate task).

CPSPLUS  := $(abspath .)
WORK     := $(CPSPLUS)/work/trigger
VECDIR   := $(WORK)/vec
CWORK    := $(CPSPLUS)/work/cps1
CVECDIR  := $(CWORK)/vec
PY       ?= python3
IVERILOG ?= iverilog
VVP      ?= vvp

RTL := ../hdl/cpsplus_trigger.v
TB  := tb_trigger.v

CPS1_RTL := ../hdl/cpsplus_cps1_tap.v
CPS1_TB  := tb_cps1_tap.v

.PHONY: trigger vectors cps1 cps1_vectors clean

trigger: $(WORK)/tb_trigger.vvp vectors
	@set -e; pass=0; fail=0; \
	while read name cfg trig stim gold; do \
	  out=$$($(VVP) $(WORK)/tb_trigger.vvp \
	         +NAME=$$name +CFG=$$cfg +TRIG=$$trig +STIM=$$stim +GOLD=$$gold); \
	  echo "$$out" | grep -E '^(PASS|FAIL|RESULT)'; \
	  if echo "$$out" | grep -q '^PASS'; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); fi; \
	done < $(VECDIR)/runs.txt; \
	echo "trigger TB: $$pass pass, $$fail fail"; test $$fail -eq 0

vectors:
	@mkdir -p $(VECDIR)
	$(PY) gen_trigger_vectors.py all --outdir $(VECDIR)

$(WORK)/tb_trigger.vvp: $(RTL) $(TB)
	@mkdir -p $(WORK)
	$(IVERILOG) -g2005 -Wall -o $@ $(RTL) $(TB)

cps1: $(CWORK)/tb_cps1_tap.vvp cps1_vectors
	@set -e; pass=0; fail=0; \
	while read name cfg trig stim gold; do \
	  out=$$($(VVP) $(CWORK)/tb_cps1_tap.vvp \
	         +NAME=$$name +CFG=$$cfg +TRIG=$$trig +STIM=$$stim +GOLD=$$gold); \
	  echo "$$out" | grep -E '^(PASS|FAIL|RESULT)'; \
	  if echo "$$out" | grep -q '^PASS'; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); fi; \
	done < $(CVECDIR)/runs.txt; \
	echo "cps1 TB: $$pass pass, $$fail fail"; test $$fail -eq 0

cps1_vectors:
	@mkdir -p $(CVECDIR)
	$(PY) gen_cps1_vectors.py all --outdir $(CVECDIR)

$(CWORK)/tb_cps1_tap.vvp: $(CPS1_RTL) $(CPS1_TB)
	@mkdir -p $(CWORK)
	$(IVERILOG) -g2005 -Wall -o $@ $(CPS1_RTL) $(CPS1_TB)

clean:
	rm -rf $(WORK) $(CWORK)
