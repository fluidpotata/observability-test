#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1


apt-get update -y
apt-get install -y git jq curl unzip python3-venv python3-pip nginx redis-server


curl https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sh


APP_DIR="/opt/flaskapp"
git clone "https://github.com/fluidpotata/observability-test.git" $APP_DIR
cd $APP_DIR


useradd -m -d /opt/flaskapp -s /bin/bash flaskuser
chown -R flaskuser:www-data $APP_DIR
sudo -u flaskuser bash -c 'python3 -m venv venv'
sudo -u flaskuser bash -c 'source venv/bin/activate && pip install wheel gunicorn && pip install -r requirements.txt'

mkdir -p /var/log/flaskapp
chown flaskuser:www-data /var/log/flaskapp
chmod 775 /var/log/flaskapp


cat << 'EOF' > /etc/fluent-bit/fluent-bit.conf
[SERVICE]
    Flush        1
    Parsers_File parsers.conf

[INPUT]
    Name         tail
    Path         /var/log/flaskapp/app.log
    Tag          flask.app
    Parser       json

[FILTER]
    Name         rewrite_tag
    Match        flask.app
    Rule         $levelname ^(WARNING|ERROR|CRITICAL)$  flask.alert  true

[OUTPUT]
    Name         loki
    Match        flask.*
    Host         127.0.0.1  # <-- CHANGE THIS TO SERVER 2 PRIVATE IP LATER
    Port         3100
    Labels       job=flask_app

[OUTPUT]
    Name         cloudwatch_logs
    Match        flask.alert
    region       ap-southeast-1
    log_group_name flask-critical-alerts
    log_stream_name app-instance-01
    auto_create_group On
EOF


cat << 'EOF' > /etc/systemd/system/flaskapp.service
[Unit]
Description=Gunicorn instance to serve flaskapp
After=network.target redis-server.service 
[Service]
User=flaskuser
Group=www-data
WorkingDirectory=/opt/flaskapp
Environment="PATH=/opt/flaskapp/venv/bin"
ExecStart=/opt/flaskapp/venv/bin/gunicorn --workers 1 --threads 4 --bind unix:flaskapp.sock -m 007 app:app
[Install]
WantedBy=multi-user.target
EOF


cat << 'EOF' > /etc/nginx/sites-available/flaskapp
server {
    listen 80;
    server_name _;
    location / {
        include proxy_params;
        proxy_pass http://unix:/opt/flaskapp/flaskapp.sock;
    }
}
EOF
ln -s /etc/nginx/sites-available/flaskapp /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default


systemctl daemon-reload
systemctl enable redis-server flaskapp nginx fluent-bit
systemctl start redis-server flaskapp nginx fluent-bit