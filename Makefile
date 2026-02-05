CID ?= $(shell docker ps -qf name=mt5)
MT5_DIR := /config/.wine/drive_c/Program Files/MetaTrader 5
EXPERTS_DIR := $(MT5_DIR)/MQL5/Experts/Downloads
INDICATORS_DIR := $(MT5_DIR)/MQL5/Indicators/Downloads

.PHONY: mq5_import mq5_export

mq5_import:
	@test -n "$(CID)" || (echo "CID not found"; exit 1)
	docker cp "$(CID):$(EXPERTS_DIR)/." "./mt5/experts/"
	docker cp "$(CID):$(INDICATORS_DIR)/." "./mt5/indicators/"


mq5_export:
	@test -n "$(CID)" || (echo "CID not found"; exit 1)
	docker cp "mt5/experts/." "$(CID):$(EXPERTS_DIR)/"
	docker cp "mt5/indicators/." "$(CID):$(INDICATORS_DIR)/"
	