#!/bin/sh
# Schickt die DHCP-Lease-Liste per MQTT an Home Assistant.
# Enthält aktive Leases (dnsmasq) plus alle festen Zuordnungen (Static Leases),
# damit die Liste auch direkt nach einem Neustart vollständig ist.
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
[ -e "$LEASEFILE" ] || LEASEFILE=/dev/null

pub() { # $1 = Topic, Payload über stdin
	mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
		${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASS:+-P "$MQTT_PASS"} \
		-i brume3-lease2mqtt -r -t "$1" -s
}

# Discovery-Konfiguration für Home Assistant (retained, einmal pro Boot/Version)
STAMP=/tmp/lease2mqtt.discovery.v2
if [ ! -e "$STAMP" ]; then
	cat <<-EOF | pub "$DISC_TOPIC" && touch "$STAMP"
	{"name":"DHCP-Leases","unique_id":"brume3_dhcp_leases","default_entity_id":"sensor.brume3_dhcp_leases",
	 "state_topic":"$TOPIC_BASE/leases","value_template":"{{ value_json.count }}",
	 "json_attributes_topic":"$TOPIC_BASE/leases",
	 "json_attributes_template":"{{ {'aktiv': value_json.aktiv, 'statisch': value_json.statisch, 'leases': value_json.leases, 'updated': value_json.updated} | tojson }}",
	 "unit_of_measurement":"Geräte","state_class":"measurement","icon":"mdi:lan-connect","expire_after":300,
	 "device":{"identifiers":["brume3"],"name":"Brume 3","manufacturer":"GL.iNet","model":"GL-MT5000","sw_version":"OpenWrt"}}
	EOF
fi

# Feste Zuordnungen aus /etc/config/dhcp: "<mac> <ip> <name>" pro Zeile
STATICS="/tmp/lease2mqtt.statics"
i=0
while uci -q get "dhcp.@host[$i]" >/dev/null; do
	ip="$(uci -q get "dhcp.@host[$i].ip")"
	name="$(uci -q get "dhcp.@host[$i].name")"
	for m in $(uci -q get "dhcp.@host[$i].mac"); do
		echo "$m ${ip:--} ${name:-*}"
	done
	i=$((i + 1))
done > "$STATICS"

# Lease-Datei (dnsmasq): <Ablauf> <MAC> <IP> <Name> <Client-ID>
awk -v now="$(date +%s)" -v ts="$(date '+%Y-%m-%d %H:%M:%S')" -v sf="$STATICS" '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
function add(ip, mac, name, rest, aktiv, statisch) {
	item = sprintf("{\"ip\":\"%s\",\"mac\":\"%s\",\"name\":\"%s\",\"restminuten\":\"%s\",\"aktiv\":%s,\"statisch\":%s}",
		esc(ip), esc(mac), esc(name), rest, aktiv, statisch)
	list = (n++ ? list "," : "") item
}
BEGIN {
	while ((getline line < sf) > 0) {
		split(line, f, " ")
		mac = tolower(f[1])
		if (mac == "" || (mac in sip)) continue
		sip[mac] = f[2]; sname[mac] = (f[3] == "*") ? "" : f[3]
		order[++k] = mac
	}
}
NF >= 4 {
	mac = tolower($2)
	seen[mac] = 1
	rest = ($1 == 0) ? "unbegrenzt" : int(($1 - now) / 60)
	name = ($4 == "*") ? "" : $4
	if (name == "" && (mac in sname)) name = sname[mac]
	st = (mac in sip) ? "true" : "false"
	add($3, mac, name, rest, "true", st)
	aktiv++
	if (st == "true") statisch++
}
END {
	for (j = 1; j <= k; j++) {
		mac = order[j]
		if (mac in seen) continue
		add(sip[mac], mac, sname[mac], "-", "false", "true")
		statisch++
	}
	printf "{\"count\":%d,\"aktiv\":%d,\"statisch\":%d,\"updated\":\"%s\",\"leases\":[%s]}", n, aktiv, statisch, ts, list
}' "$LEASEFILE" | pub "$TOPIC_BASE/leases"
