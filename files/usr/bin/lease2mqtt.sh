#!/bin/sh
# Schickt die aktuelle DHCP-Lease-Liste per MQTT an Home Assistant.
# Konfiguration: /etc/lease2mqtt.conf (MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS)
# Aufruf per Cron jede Minute.

CONF=/etc/lease2mqtt.conf
[ -r "$CONF" ] || exit 0
. "$CONF"

MQTT_PORT="${MQTT_PORT:-1883}"
TOPIC_BASE="${TOPIC_BASE:-brume3/dhcp}"
DISC_TOPIC="homeassistant/sensor/brume3_dhcp_leases/config"

LEASEFILE="$(uci -q get dhcp.@dnsmasq[0].leasefile)"
LEASEFILE="${LEASEFILE:-/tmp/dhcp.leases}"
[ -r "$LEASEFILE" ] || exit 0

pub() { # $1 = Topic, Payload über stdin
	mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
		${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASS:+-P "$MQTT_PASS"} \
		-i brume3-lease2mqtt -r -t "$1" -s
}

# Discovery-Konfiguration für Home Assistant (retained, einmal pro Boot reicht)
STAMP=/tmp/lease2mqtt.discovery
if [ ! -e "$STAMP" ]; then
	cat <<-EOF | pub "$DISC_TOPIC" && touch "$STAMP"
	{"name":"DHCP-Leases","unique_id":"brume3_dhcp_leases","default_entity_id":"sensor.brume3_dhcp_leases",
	 "state_topic":"$TOPIC_BASE/leases","value_template":"{{ value_json.count }}",
	 "json_attributes_topic":"$TOPIC_BASE/leases",
	 "json_attributes_template":"{{ {'leases': value_json.leases, 'updated': value_json.updated} | tojson }}",
	 "unit_of_measurement":"Geräte","state_class":"measurement","icon":"mdi:lan-connect","expire_after":300,
	 "device":{"identifiers":["brume3"],"name":"Brume 3","manufacturer":"GL.iNet","model":"GL-MT5000","sw_version":"OpenWrt"}}
	EOF
fi

# Lease-Datei (dnsmasq): <Ablauf> <MAC> <IP> <Name> <Client-ID>
NOW="$(date +%s)"
awk -v now="$NOW" -v ts="$(date '+%Y-%m-%d %H:%M:%S')" '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
NF >= 4 {
	rest = ($1 == 0) ? "unbegrenzt" : int(($1 - now) / 60)
	name = ($4 == "*") ? "" : $4
	item = sprintf("{\"ip\":\"%s\",\"mac\":\"%s\",\"name\":\"%s\",\"restminuten\":\"%s\"}", esc($3), esc($2), esc(name), rest)
	list = (n++ ? list "," : "") item
}
END {
	printf "{\"count\":%d,\"updated\":\"%s\",\"leases\":[%s]}", n, ts, list
}' "$LEASEFILE" | pub "$TOPIC_BASE/leases"
