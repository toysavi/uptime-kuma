FROM louislam/uptime-kuma:2.1.3

# Optional: custom config or additions
EXPOSE 3001

VOLUME ["/app/data"]
```

# ## How It Works

# | Step | What Happens |
# |------|-------------|
# | Trigger | Runs on every push to `main` or manually |
# | Login | Uses your `DOCKER_USERNAME` + `DOCKER_PASSWORD` secrets |
# | Build | Builds the image from your `Dockerfile` |
# | Push | Pushes two tags: `2.1.3` and `latest` |
# | Cache | GitHub Actions cache speeds up future builds |

# ## Result on Docker Hub

# Your image will be available at:
# ```
# docker.io/<your-username>/uptime-kuma:2.1.3
# docker.io/<your-username>/uptime-kuma:latest