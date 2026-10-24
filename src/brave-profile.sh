#!/bin/bash
# Generates the (optional) configuration profile that forces Brave through
# Mullvad's internal SOCKS5 proxy (10.64.0.1:1080). That proxy is only reachable
# through a Mullvad tunnel, so Brave fails closed if it is ever opened outside
# the VPN, and it resolves hostnames (DNS) at Mullvad instead of your ISP.
# usage: brave-profile.sh <output.mobileconfig>
set -euo pipefail
out="${1:?usage: brave-profile.sh <output.mobileconfig>}"
u1=$(uuidgen); u2=$(uuidgen)
cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.ManagedClient.preferences</string>
			<key>PayloadIdentifier</key>
			<string>local.vpnselectivo.brave.policy</string>
			<key>PayloadUUID</key>
			<string>$u1</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadDisplayName</key>
			<string>Brave: Mullvad proxy</string>
			<key>PayloadContent</key>
			<dict>
				<key>com.brave.Browser</key>
				<dict>
					<key>Forced</key>
					<array>
						<dict>
							<key>mcx_preference_settings</key>
							<dict>
								<key>ProxySettings</key>
								<dict>
									<key>ProxyMode</key>
									<string>fixed_servers</string>
									<key>ProxyServer</key>
									<string>socks5://10.64.0.1:1080</string>
								</dict>
								<!-- No Cast discovery: avoids mDNS/SSDP multicast to the local
								     network, which PF cannot attribute to Brave (shared port). -->
								<key>EnableMediaRouter</key>
								<false/>
							</dict>
						</dict>
					</array>
				</dict>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>VPN Selectivo — Brave: Mullvad only</string>
	<key>PayloadDescription</key>
	<string>Forces Brave to use Mullvad's internal SOCKS5 proxy (10.64.0.1:1080), reachable only inside the tunnel. Without the VPN, Brave has no connection. Remove this profile to restore normal behaviour.</string>
	<key>PayloadIdentifier</key>
	<string>local.vpnselectivo.brave</string>
	<key>PayloadOrganization</key>
	<string>VPN Selectivo (local)</string>
	<key>PayloadScope</key>
	<string>User</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>$u2</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF
plutil -lint -s "$out"
