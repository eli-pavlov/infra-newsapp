# --- App Source Repos ---
https://github.com/ghGill/newsAppFront
https://github.com/ghGill/newsAppbackend

# --- Frontend build-time (Vite) ---
VITE_SERVER_URL={{VITE_SERVER_URL}}                    # e.g. /api
VITE_NEWS_INTERVAL_IN_MIN={{VITE_NEWS_INTERVAL_IN_MIN}}  # e.g. 5

# --- Frontend runtime (Nginx proxy target) ---
BACKEND_SERVICE_HOST={{BACKEND_SERVICE_HOST}}          # e.g. backend.default.svc.cluster.local
BACKEND_SERVICE_PORT={{BACKEND_SERVICE_PORT}}          # e.g. 8080

# --- Backend DB config (example) ---
# MONGO | MONGOOSE | POSTGRES | MYSQL
DB_ENGINE_TYPE={{DB_ENGINE_TYPE}}
# connection string : [protocol]://[username]:[password]@[host]:[port]/[database]
DB_PROTOCOL= ( required, without :// )
DB_USER= ( can be empty, optional )
DB_PASSWORD= ( can be empty, optional )
DB_HOST= ( required )
DB_PORT= ( can be empty, optional ) 
DB_NAME= ( required )

# AWS_S3 | DISK
STORAGE_TYPE=

# In case of STORAGE_TYPE = AWS_S3
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=
AWS_BUCKET= [ the name of the bucket where to create the movies folder ]

# In case of STORAGE_TYPE = DISK
DISK_ROOT_PATH= [ full path on disk to the root directory where to create the movies folder ]

# Frontend commit info
VITE_FRONTEND_GIT_BRANCH=
VITE_FRONTEND_GIT_COMMIT=
# Backedn commit info
BACKEND_GIT_BRANCH=
BACKEND_GIT_COMMIT