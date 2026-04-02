<?php

$overwriteHost = getenv('OVERWRITEHOST');
if ($overwriteHost) {
  $CONFIG['overwritehost'] = $overwriteHost;
}

$overwriteProtocol = getenv('OVERWRITEPROTOCOL');
if ($overwriteProtocol) {
  $CONFIG['overwriteprotocol'] = $overwriteProtocol;
}

$overwriteCliUrl = getenv('OVERWRITECLIURL');
if ($overwriteCliUrl) {
  $CONFIG['overwrite.cli.url'] = $overwriteCliUrl;
}

$overwriteWebRoot = getenv('OVERWRITEWEBROOT');
if ($overwriteWebRoot) {
  $CONFIG['overwritewebroot'] = $overwriteWebRoot;
}

$overwriteCondAddr = getenv('OVERWRITECONDADDR');
if ($overwriteCondAddr) {
  $CONFIG['overwritecondaddr'] = $overwriteCondAddr;
}

$trustedProxies = getenv('TRUSTED_PROXIES');
if ($trustedProxies) {
  // Accept both comma-separated and space-separated values.
  $CONFIG['trusted_proxies'] = array_values(array_filter(array_map('trim', preg_split('/[\s,]+/', $trustedProxies))));
}

$forwardedForHeaders = getenv('FORWARDED_FOR_HEADERS');
if ($forwardedForHeaders) {
  $CONFIG['forwarded_for_headers'] = array_values(array_filter(array_map('trim', preg_split('/[\s,]+/', $forwardedForHeaders))));
}

$maintenanceWindowStart = getenv('NEXTCLOUD_MAINTENANCE_WINDOW_START');
if ($maintenanceWindowStart !== false && $maintenanceWindowStart !== '') {
  $CONFIG['maintenance_window_start'] = (int) $maintenanceWindowStart;
}

$defaultPhoneRegion = getenv('NEXTCLOUD_DEFAULT_PHONE_REGION');
if ($defaultPhoneRegion) {
  $CONFIG['default_phone_region'] = strtoupper(trim($defaultPhoneRegion));
}

$trustedDomains = getenv('NEXTCLOUD_TRUSTED_DOMAINS');
$runtimeTrustedDomains = ['localhost', '127.0.0.1'];
if ($trustedDomains) {
  $runtimeTrustedDomains = array_merge($runtimeTrustedDomains, array_values(array_filter(array_map('trim', preg_split('/[\s,]+/', $trustedDomains)))));
}

$existingTrustedDomains = [];
if (isset($CONFIG['trusted_domains']) && is_array($CONFIG['trusted_domains'])) {
  $existingTrustedDomains = array_values(array_filter(array_map('strval', $CONFIG['trusted_domains'])));
}

$CONFIG['trusted_domains'] = array_values(array_unique(array_merge($existingTrustedDomains, $runtimeTrustedDomains)));

$CONFIG['hide_login_form'] = true;

$CONFIG['allow_local_remote_servers'] = true;

$CONFIG['auth.bruteforce.protection.enabled'] = true;

$CONFIG['shareapi_allow_custom_url'] = true;

$CONFIG['skeletondirectory'] = '';

$redisHost = getenv('REDIS_HOST');
if ($redisHost) {
  $CONFIG['memcache.local'] = '\\OC\\Memcache\\APCu';
  $CONFIG['memcache.distributed'] = '\\OC\\Memcache\\Redis';
  $CONFIG['memcache.locking'] = '\\OC\\Memcache\\Redis';
  $CONFIG['redis'] = [
    'host' => $redisHost,
    'port' => (int) (getenv('REDIS_HOST_PORT') ?: 6379),
    'timeout' => 1.5,
  ];
}
