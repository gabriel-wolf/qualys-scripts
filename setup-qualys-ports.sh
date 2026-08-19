#!/bin/bash
# Description: Safely opens TCP ports 10001-10005 for Qualys Scanners and Automation Host.

# Ensure script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root or with sudo."
    exit 1
fi

PORTS="10001:10005"
PORTS_DASH="10001-10005"
SOURCES=("<IP RANGE OF SCANNERS GOES HERE>")

echo "Detecting active Linux firewall subsystem..."

# 1. Firewalld (Oracle Linux, RHEL, CentOS, Rocky, Fedora)
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "Active firewall manager: firewalld"
    for src in "${SOURCES[@]}"; do
        echo "Adding rule for source: $src"
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$src\" port port=\"$PORTS_DASH\" protocol=\"tcp\" accept"
    done
    firewall-cmd --reload
    echo "Firewalld rules successfully updated and reloaded."

# 2. UFW (Ubuntu, Debian)
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "Active firewall manager: UFW"
    for src in "${SOURCES[@]}"; do
        echo "Adding rule for source: $src"
        ufw allow from "$src" to any port "$PORTS" proto tcp comment 'Qualys Agent Correlation'
    done
    ufw reload
    echo "UFW rules successfully updated and reloaded."

# 3. Static iptables configuration file (/etc/sysconfig/iptables)
elif [ -f /etc/sysconfig/iptables ]; then
    echo "Active firewall manager: Static /etc/sysconfig/iptables file"
    
    # Insert rules directly above the default REJECT or DROP rule inside the filter table
    for src in "${SOURCES[@]}"; do
        RULE="-A INPUT -s $src -p tcp -m state --state NEW -m tcp --dport $PORTS -j ACCEPT"
        if ! grep -qF "$src" /etc/sysconfig/iptables; then
            sed -i "/-A INPUT -j REJECT/i $RULE" /etc/sysconfig/iptables 2>/dev/null || \
            sed -i "/-A INPUT -j DROP/i $RULE" /etc/sysconfig/iptables
        fi
    done
    
    # Restart iptables service to load modified config
    if systemctl is-active --quiet iptables; then
        systemctl restart iptables
    elif service iptables status >/dev/null 2>&1; then
        service iptables restart
    fi
    echo "/etc/sysconfig/iptables updated and service restarted."

# 4. Fallback to active runtime iptables
elif command -v iptables >/dev/null 2>&1; then
    echo "Active firewall manager: Generic iptables"
    for src in "${SOURCES[@]}"; do
        # Insert at the top (position 1) to ensure it precedes any generic DROP/REJECT rules
        iptables -I INPUT 1 -s "$src" -p tcp --dport "$PORTS" -m comment --comment "Qualys Agent Correlation" -j ACCEPT
    done

    # Attempt rule persistence across reboots
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
    fi
    echo "iptables runtime rules applied successfully."

else
    echo "Error: No active or supported firewall framework was detected."
    exit 1
fi
