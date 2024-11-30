include env.sh
# 変数定義 ------------------------

# SERVER_ID: env.sh内で定義

# 問題によって変わる変数
USER:=isucon
BIN_NAME:=isuconquest
BUILD_DIR:=/home/isucon/webapp/go
SERVICE_NAME:=$(BIN_NAME).go.service

DB_PATH:=/etc/mysql
NGINX_PATH:=/etc/nginx
SYSTEMD_PATH:=/etc/systemd/system

NGINX_LOG:=/var/log/nginx/access.log
DB_SLOW_LOG:=/var/log/mysql/mariadb-slow.log
TBLS_VERSION:=1.71.1

# http://localhost:19999/netdata.confのdirectories.webで確認可能
NETDATA_WEBROOT_PATH:= /var/lib/netdata/www/
NETDATA_CUSTOM_HTML:= ./tool-config/netdata/*

WEBHOOK_URL = https://discord.com/api/webhooks/1175019426396000296/6F9rMmDjObZInViXR47xJ4cU55RNjdH6CbsIQnF0tjCEHcGjFL0QFBDHRyezp-1ex8Pk

# メインで使うコマンド ------------------------

# サーバーの環境構築　ツールのインストール、gitまわりのセットアップ
.PHONY: setup
setup: install-tools git-setup set-nginx-alp-ltsv  

# 設定ファイルなどを取得してgit管理下に配置する
.PHONY: get-conf
get-conf: check-server-id get-db-conf get-nginx-conf get-service-file get-envsh

# リポジトリ内の設定ファイルをそれぞれ配置する
.PHONY: deploy-conf
deploy-conf: check-server-id deploy-db-conf deploy-nginx-conf deploy-service-file deploy-envsh

# ベンチマークを走らせる直前に実行する
.PHONY: bench
bench: check-server-id mv-logs build  restart slow-on

# slow queryを確認する
.PHONY: slow-query
slow-query:
	sudo mysqldumpslow -s t -t 10 $(MYSQL_LOG) 
	sudo pt-query-digest $(DB_SLOW_LOG)
	
# alpでアクセスログを確認する
.PHONY: alp
alp:
	sudo alp ltsv --file=$(NGINX_LOG)  --config=./tool-config/alp/config.yaml

# fgprofで記録する
.PHONY: fgprof-record
fgprof-record:
	go tool pprof -top http://localhost:6060/debug/fgprof?seconds=60 > /temp/fgprof.txt
	-@curl -X POST -F txt=@/temp/fgprof.txt $(WEBHOOK_URL) -s -o /dev/null

# pprofで記録する
.PHONY: pprof-record
pprof-record:
	go tool pprof -top http://localhost:6060/debug/pprof/profile?seconds=60 > /temp/pprof.txt
	-@curl -X POST -F txt=@/temp/pprof.txt $(WEBHOOK_URL) -s -o /dev/null

# pprof or fgprofで確認する
.PHONY: go-check
go-check:
	$(eval latest := $(shell ls -rt pprof/ | tail -n 1))
	go tool pprof -http=localhost:8090 pprof/$(latest)

.PHONY: analyze
analyze:
	sudo mkdir -p /temp && sudo chmod 777 /temp
	sudo alp ltsv --file=$(NGINX_LOG)  --config=./tool-config/alp/config.yaml > /temp/alp.txt
	-@curl -X POST -F txt=@/temp/alp.txt $(WEBHOOK_URL) -s -o /dev/null
	sudo mysqldumpslow -s t -t 10 $(DB_SLOW_LOG) > /temp/mysqldumpslow.txt
	-@curl -X POST -F txt=@/temp/mysqldumpslow.txt $(WEBHOOK_URL) -s -o /dev/null
	sudo pt-query-digest --limit 15 --type slowlog $(DB_SLOW_LOG) > /temp/pt-query-digest.txt
	-@curl -X POST -F txt=@/temp/pt-query-digest.txt $(WEBHOOK_URL) -s -o /dev/null
	

# DBに接続する
.PHONY: db
db:
	mysql -h $(MYSQL_HOST) -P $(MYSQL_PORT) -u $(MYSQL_USER) -p$(MYSQL_PASS) $(MYSQL_DBNAME)

# tbls
.PHONY: tbls
tbls:
	tbls doc  --force mysql://$(MYSQL_USER):$(MYSQL_PASS)@$(MYSQL_HOST):$(MYSQL_PORT)/$(MYSQL_DBNAME)

.PHONY: slow-on
slow-on:
	sudo mysql -e "set global slow_query_log_file = '$(DB_SLOW_LOG)'; set global long_query_time = 0; set global slow_query_log = ON;"
	# sudo $(MYSQL_CMD) -e "set global slow_query_log_file = '$(DB_SLOW_LOG)'; set global long_query_time = 0; set global slow_query_log = ON;"

.PHONY: slow-off
slow-off:
	sudo mysql -e "set global slow_query_log = OFF;"
	# sudo $(MYSQL_CMD) -e "set global slow_query_log = OFF;"



.PHONY: stat
stat:
	@tmux split-window -h -p 50
	@tmux split-window -v -p 50
	@tmux select-pane -t 0
	@tmux split-window -v -p 50
	@tmux send-keys -t 0 "sudo journalctl -u $(SERVICE_NAME) -f" C-m
	@tmux send-keys -t 2 "htop" C-m
	@tmux send-keys -t 3 "dstat" C-m

# 主要コマンドの構成要素 ------------------------

.PHONY: set-nginx-alp-ltsv
set-nginx-alp-ltsv:
	@sudo sed -i '/http {/a\\    log_format ltsv \"time:\$$time_local\"\n\t\t    \"\\thost:\$$remote_addr\"\n\t\t    \"\\tforwardedfor:\$$http_x_forwarded_for\"\n\t\t    \"\\treq:\$$request\"\n\t\t    \"\\tstatus:\$$status\"\n\t\t    \"\\tmethod:\$$request_method\"\n\t\t    \"\\turi:\$$request_uri\"\n\t\t    \"\\tsize:\$$body_bytes_sent\"\n\t\t    \"\\treferer:\$$http_referer\"\n\t\t    \"\\tua:\$$http_user_agent\"\n\t\t    \"\\treqtime:\$$request_time\"\n\t\t    \"\\tcache:\$$upstream_http_x_cache\"\n\t\t    \"\\truntime:\$$upstream_http_x_runtime\"\n\t\t    \"\\tapptime:\$$upstream_response_time\"\n\t\t    \"\\tvhost:\$$host\";\n' /etc/nginx/nginx.conf
	@sudo sed -i 's@access_log  /var/log/nginx/access.log  main;@access_log  /var/log/nginx/access.log  ltsv;@g' /etc/nginx/nginx.conf
	sudo systemctl restart nginx.service

.PHONY: install-tools
install-tools:
	sudo apt update -y
	sudo apt upgrade -y
	sudo apt install -y percona-toolkit dstat git unzip snapd graphviz tree htop
	sudo apt install -y build-essential curl wget vim

	# alpのインストール
	wget https://github.com/tkuchiki/alp/releases/download/v1.0.9/alp_linux_amd64.zip
	unzip alp_linux_amd64.zip
	sudo install alp /usr/local/bin/alp
	rm alp_linux_amd64.zip alp

	curl -o tbls.deb -L https://github.com/k1LoW/tbls/releases/download/v$(TBLS_VERSION)/tbls_$(TBLS_VERSION)-1_amd64.deb
	sudo dpkg -i tbls.deb
	rm tbls.deb

	# netdataのインストール
	- wget -O /tmp/netdata-kickstart.sh https://my-netdata.io/kickstart.sh && sh /tmp/netdata-kickstart.sh --no-updates --stable-channel --disable-telemetry --yes

.PHONY: git-setup
git-setup:
	# git用の設定は適宜変更して良い
	git config --global user.name "server"
	git config --global user.email "github-actions[bot]@users.noreply.github.com"
	git config --global init.defaultbranch main

.PHONY: check-server-id
check-server-id:
ifdef SERVER_ID
	@echo "SERVER_ID=$(SERVER_ID)"
else
	@echo "SERVER_ID is unset"
	@exit 1
endif

.PHONY: set-as-s1
set-as-s1:
	touch ~/env.sh
	echo "SERVER_ID=s1" >> ~/env.sh

.PHONY: set-as-s2
set-as-s2:
	touch ~/env.sh
	echo "SERVER_ID=s2" >> ~/env.sh

.PHONY: set-as-s3
set-as-s3:
	touch ~/env.sh
	echo "SERVER_ID=s3" >> ~/env.sh

.PHONY: get-db-conf
get-db-conf:
	sudo cp -R $(DB_PATH)/* ./$(SERVER_ID)/etc/mysql
	sudo chown $(USER) -R ./$(SERVER_ID)/etc/mysql

.PHONY: get-nginx-conf
get-nginx-conf:
	sudo cp -R $(NGINX_PATH)/* ./$(SERVER_ID)/etc/nginx
	sudo chown $(USER) -R ./$(SERVER_ID)/etc/nginx

.PHONY: get-service-file
get-service-file:
	sudo cp $(SYSTEMD_PATH)/$(SERVICE_NAME) ./$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)
	sudo chown $(USER) ./$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)

.PHONY: get-envsh
get-envsh:
	cp ~/env.sh ./$(SERVER_ID)/home/isucon/env.sh

.PHONY: deploy-db-conf
deploy-db-conf:
	sudo cp -R ./$(SERVER_ID)/etc/mysql/* $(DB_PATH)

.PHONY: deploy-nginx-conf
deploy-nginx-conf:
	sudo cp -R ./$(SERVER_ID)/etc/nginx/* $(NGINX_PATH)

.PHONY: deploy-service-file
deploy-service-file:
	sudo cp ./$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME) $(SYSTEMD_PATH)/$(SERVICE_NAME)

.PHONY: deploy-envsh
deploy-envsh:
	cp ./$(SERVER_ID)/home/isucon/env.sh ~/env.sh

.PHONY: build
build:
	cd $(BUILD_DIR); \
	go build -o $(BIN_NAME)

.PHONY: restart
restart:
	sudo systemctl daemon-reload
	sudo systemctl restart $(SERVICE_NAME)
	sudo systemctl restart mysql
	sudo systemctl restart nginx

.PHONY: mv-logs
mv-logs:
	$(eval when := $(shell date +"%M_%H_%d_%m_%Y"))
	mkdir -p ./$(SERVER_ID)/logs/$(when)
	sudo test -f $(NGINX_LOG) && \
		sudo mv -f $(NGINX_LOG) ./$(SERVER_ID)/logs/$(when)/nginx || echo ""
	sudo touch $(NGINX_LOG)
	sudo systemctl restart nginx.service
	sudo test -f $(DB_SLOW_LOG) && \
		sudo mv -f $(DB_SLOW_LOG) ./$(SERVER_ID)/logs/$(when)/mysql || echo ""
	sudo touch $(DB_SLOW_LOG)
	sudo chmod 777 $(DB_SLOW_LOG)
	sudo systemctl restart mysql
	sudo rm -rf ./$(SERVER_ID)/logs/*

.PHONY: watch-service-log
watch-service-log:
	sudo journalctl -u $(SERVICE_NAME) -n10 -f

.PHONY: netdata-setup
netdata-setup:
	sudo cp -R $(NETDATA_CUSTOM_HTML) $(NETDATA_WEBROOT_PATH)
	sudo systemctl restart netdata


