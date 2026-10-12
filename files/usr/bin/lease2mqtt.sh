#!/bin/sh
# Schickt die DHCP-Lease-Liste per MQTT an Home Assistant.
# Enthält aktive Leases (dnsmasq) plus alle festen Zuordnungen (Static Leases),
# damit die Liste auch direkt nach einem Neustart vollständig ist.
# Konfiguration: /etc/lease2mqtt.conf (MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS)
# Aufruf per Cron jede Minute.

CONF=/etc/lease2mqtt.conf
[ -r "$CONF" ] || exit 0
. "$CONF"

# Nur eine Instanz gleichzeitig (gleiche MQTT-Client-ID würde sich sonst gegenseitig trennen)
LOCK=/tmp/lease2mqtt.lock
if ! mkdir "$LOCK" 2>/dev/null; then
	# Verwaiste Sperre (älter als 5 min) aufräumen, sonst diesen Lauf auslassen
	[ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

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

# ---------------------------------------------------------------------------
# Anwesenheit per Gerätename (unabhängig von wechselnden MAC-Adressen)
# In /etc/lease2mqtt.conf:  PRESENCE_1='Mieter 1|S25-al-utilizatorului-Dan'
#                           PRESENCE_2='Mieter 2|S25-di-Camelia'   (bis PRESENCE_9)
# Optional: PRESENCE_TIMEOUT=600 (Sekunden ohne Antwort bis "abwesend")
# Erzeugt in HA z. B. binary_sensor.mieter_1_anwesend und device_tracker.mieter_1_handy
# ---------------------------------------------------------------------------
TIMEOUT="${PRESENCE_TIMEOUT:-600}"

# Ist das Gerät gerade erreichbar? 1) Passiv: Kernel hat kürzlich Verkehr
# bestätigt (REACHABLE). 2) Aktiv: frische ARP-Anfrage, bis zu 3 Versuche.
# ARP beantwortet der WLAN-Chip meist auch im Ruhezustand.
seen_now() { # $1 = IP, $2 = MAC (klein)
	ip neigh show to "$1" | grep -qiE "lladdr $2 .*REACHABLE" && return 0
	for try in 1 2 3; do
		ip neigh flush to "$1" 2>/dev/null
		ping -c 1 -W 1 "$1" >/dev/null 2>&1
		ip neigh show to "$1" | grep -qi "lladdr $2" && return 0
		sleep 1
	done
	return 1
}
NOW="$(date +%s)"
for n in 1 2 3 4 5 6 7 8 9; do
	eval "entry=\${PRESENCE_$n}"
	[ -n "$entry" ] || continue
	label="${entry%%|*}"
	host="${entry#*|}"
	slug="$(echo "$label" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_')"
	topic="$TOPIC_BASE/presence/$slug"
	seenfile="/tmp/lease2mqtt.seen.$slug"

	if [ ! -e "/tmp/lease2mqtt.discovery.presence.v2.$slug" ]; then
		cat <<-EOF | pub "homeassistant/binary_sensor/brume3_presence_$slug/config" && touch "/tmp/lease2mqtt.discovery.presence.v2.$slug"
		{"name":"$label anwesend","unique_id":"brume3_presence_$slug","default_entity_id":"binary_sensor.${slug}_anwesend",
		 "state_topic":"$topic","json_attributes_topic":"$topic/attr",
		 "payload_on":"ON","payload_off":"OFF","device_class":"presence","expire_after":600,
		 "device":{"identifiers":["brume3"],"name":"Brume 3","manufacturer":"GL.iNet","model":"GL-MT5000","sw_version":"OpenWrt"}}
		EOF
	fi
	# Zusätzlich als Device-Tracker (nur solche lassen sich Personen zuordnen)
	if [ ! -e "/tmp/lease2mqtt.discovery.tracker.$slug" ]; then
		cat <<-EOF | pub "homeassistant/device_tracker/brume3_tracker_$slug/config" && touch "/tmp/lease2mqtt.discovery.tracker.$slug"
		{"name":"$label Handy","unique_id":"brume3_tracker_$slug","default_entity_id":"device_tracker.${slug}_handy",
		 "state_topic":"$topic/tracker","json_attributes_topic":"$topic/attr",
		 "payload_home":"home","payload_not_home":"not_home","source_type":"router",
		 "device":{"identifiers":["brume3"],"name":"Brume 3","manufacturer":"GL.iNet","model":"GL-MT5000","sw_version":"OpenWrt"}}
		EOF
	fi

	# Alle aktuellen Leases mit diesem Namen prüfen (alte MACs haben evtl. noch eine)
	found_ip=""; found_mac=""
	for pair in $(awk -v h="$host" 'NF >= 4 && tolower($4) == tolower(h) { print $3 "," tolower($2) }' "$LEASEFILE"); do
		ip="${pair%%,*}"; mac="${pair#*,}"
		if seen_now "$ip" "$mac"; then
			found_ip="$ip"; found_mac="$mac"; echo "$NOW" > "$seenfile"
			break
		fi
	done

	last="$(cat "$seenfile" 2>/dev/null || echo 0)"
	if [ $((NOW - last)) -lt "$TIMEOUT" ]; then state=ON; else state=OFF; fi
	printf "%s" "$state" | pub "$topic"
	if [ "$state" = ON ]; then printf home; else printf not_home; fi | pub "$topic/tracker"
	if [ "$last" -gt 0 ]; then
		lastts="$(date -d "@$last" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last")"
	else
		lastts="-"
	fi
	printf '{"geraetename":"%s","ip":"%s","mac":"%s","zuletzt_gesehen":"%s"}' \
		"$host" "${found_ip:--}" "${found_mac:--}" "$lastts" | pub "$topic/attr"
done
