Mollie payments for Zotonic
===========================

This is a Payment Service Provider (PSP) module for mod_payment:

    https://github.com/driebit/mod_payment

This module interfaces mod_payment to the PSP Mollie (https://mollie.com/)


Configuration
-------------

The following configuration keys can be set:

 * `mod_payment_mollie.api_key` the secret API key for Mollie API requests. Be
   sure to use the *test* key when developing.

Development configuration
-------------------------

 * `mod_payment_mollie.webhook_host` this should be the host (with `http:` prefix)
   where Mollie should send the webhook messages. Only use this if your (development)
   site is reachable from the outside via a different URL than the configured hostnames.
