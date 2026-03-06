<?php

$trustedProxies = getenv('TRUSTED_PROXIES');
if ($trustedProxies) {
  // Accept both comma-separated and space-separated values.
  $CONFIG['trusted_proxies'] = array_values(array_filter(array_map('trim', preg_split('/[\s,]+/', $trustedProxies))));
}
