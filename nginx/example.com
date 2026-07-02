# fragment for nginx configuration

# Browser preferred language detection
map $http_accept_language $accept_language {
   ~*^de de;
   ~*^en en;
}

# vhost example.com

	# Serves the coverage-website build output (see ansible/playbook.yml's
	# "coverage-website: build the frontend from source and deploy it"
	# tasks, which build it and copy dist/frq-map/{de,en}/ here).
	root /var/www/frq;

    # Fallback to default language if no preference defined by browser
	if ($accept_language ~ "^$") {
            set $accept_language "de";
	}

	rewrite ^/$ /$accept_language permanent;
	location ~ ^/(de|en) {
	        try_files $uri /$1/index.html?$args;
        }

	# web page
	location / {
	}

	# tiles
        location /cov {
                try_files $uri /cov/dummy.png;
		autoindex on;
		root /var/www/tiles;
        }

	# endpoint /settings
        location /api/settings {
                proxy_pass http://127.0.0.1:3000/settings;
        }

	# endpoint /tileurl
        location /api/tileurl  {
                proxy_pass http://127.0.0.1:3000/tileurl;
        }

	# endpoint /rpc/cov
        location /api/rpc/cov  {
                proxy_pass http://127.0.0.1:3000/rpc/cov;
        }

	# endpoint /rpc/id (used by the frontend's point-info panel — added
	# here because it was missing from this fragment despite being called
	# already; verify whether real production nginx already has this
	# under a location block not reflected in this checked-in file)
        location /api/rpc/id  {
                proxy_pass http://127.0.0.1:3000/rpc/id;
        }

	# endpoint /layers (new — replaces /api/settings' operator list)
        location /api/layers  {
                proxy_pass http://127.0.0.1:3000/layers;
        }

	# endpoint /layer_obligations (new — replaces /api/settings' nested obligations)
        location /api/layer_obligations  {
                proxy_pass http://127.0.0.1:3000/layer_obligations;
        }

	# endpoint /rpc/cov_layer (new — replaces /api/rpc/cov for the frontend's point-info)
        location /api/rpc/cov_layer  {
                proxy_pass http://127.0.0.1:3000/rpc/cov_layer;
        }

	# endpoint /rpc/layer_tileurl (new — replaces /api/tileurl?operator=eq... for the frontend's map overlay)
        location /api/rpc/layer_tileurl  {
                proxy_pass http://127.0.0.1:3000/rpc/layer_tileurl;
        }

	# background map using cache
	location /basemap/ {
		add_header X-License 'geoland.at - Creative Commons Namensnennung 4.0 International';
		proxy_pass https://maps.wien.gv.at/basemap/;
                proxy_buffering        on;
                add_header X-cache-Status $upstream_cache_status;
                add_header X-cache-Date $upstream_http_date;
                proxy_cache            MAP;
                proxy_cache_valid      200  14d;
                proxy_cache_use_stale  error timeout invalid_header updating
                                   http_500 http_502 http_503 http_504;
	}
