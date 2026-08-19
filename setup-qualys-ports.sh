#!/bin/bash
# Qualys CAR Script: Idempotent Firewall Config for Agent Correlation Ports (10001-10005)
# Target IPs: 129.118.5.0/24 (Qualys Scanners)

PORTS="10001:10005"
PORTS_DASH="10001-10005"
SOURCES=("<SCANNER IP RANGE GOES HERE>")

echo "Starting firewall configuration for Qualys Agent Correlation Identifier..."

# 1. Firewalld (Oracle Linux, RHEL, CentOS, Rocky, AlmaLinux, Fedora)
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "Detected Firewalld."
    for src in "${SOURCES[@]}"; do
        # Check if rule already exists before adding
        if ! firewall-cmd --query-rich-rule="rule family=\"ipv4\" source address=\"$src\" port port=\"$PORTS_DASH\" protocol=\"tcp\" accept" >/dev/null 2>&1; then
            firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$src\" port port=\"$PORTS_DASH\" protocol=\"tcp\" accept"
            RELOAD_NEEDED=1
        fi
    done
    if [ "$RELOAD_NEEDED" = "1" ]; then
        firewall-cmd --reload
        echo "SUCCESS: Firewalld updated and reloaded."
    else
        echo "SUCCESS: Firewalld rules already present."
    fi
    exit 0

# 2. UFW (Ubuntu, Debian)
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "Detected UFW."
    for src in "${SOURCES[@]}"; do
        if ! ufw status | grep -q "$src.*10001:10005"; then
            ufw allow from "$src" to any port "$PORTS" proto tcp comment 'Qualys Agent Correlation'
            RELOAD_NEEDED=1
        fi
    done
    if [ "$RELOAD_NEEDED" = "1" ]; then
        ufw reload
        echo "SUCCESS: UFW updated."
    else
        echo "SUCCESS: UFW rules already present."
    fi
    exit 0

# 3. Static /etc/sysconfig/iptables (Oracle Linux / RHEL legacy)
elif [ -f /etc/sysconfig/iptables ]; then
    echo "Detected /etc/sysconfig/iptables file."
    MODIFIED=0
    for src in "${SOURCES[@]}"; do
        RULE="-A INPUT -s $src -p tcp -m state --state NEW -m tcp --dport $PORTS -j ACCEPT"
        if ! grep -qF "$src" /etc/sysconfig/iptables; then
            sed -i "/-A INPUT -j REJECT/i $RULE" /etc/sysconfig/iptables 2>/dev/null || \
            sed -i "/-A INPUT -j DROP/i $RULE" /etc/sysconfig/iptables
            MODIFIED=1
        fi
    done
    
    if [ "$MODIFIED" = "1" ]; then
        if systemctl is-active --quiet iptables; then
            systemctl restart iptables
        elif service iptables status >/dev/null 2>&1; then
            service iptables restart
        fi
        echo "SUCCESS: /etc/sysconfig/iptables updated and service restarted."
    else
        echo "SUCCESS: iptables configuration already up to date."
    fi
    exit 0

# 4. Fallback Generic Runtime iptables
elif command -v iptables >/dev/null 2>&1; then
    echo "Detected generic iptables."
    for src in "${SOURCES[@]}"; do
        if ! iptables -C INPUT -s "$src" -p tcp --dport "$PORTS" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT 1 -s "$src" -p tcp --dport "$PORTS" -m comment --comment "Qualys Agent Correlation" -j ACCEPT
            MODIFIED=1
        fi
    done

    if [ "$MODIFIED" = "1" ]; then
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4
        fi
        echo "SUCCESS: Runtime iptables updated."
    else
        echo "SUCCESS: iptables rules already present."
    fi
    exit 0

else
    echo "ERROR: No active or supported firewall framework was detected."
    exit 1
fi
