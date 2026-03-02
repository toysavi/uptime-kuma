FROM louislam/uptime-kuma:2.1.3

EXPOSE 3001

VOLUME ["/app/data"]
```

## What Went Wrong

Your `Dockerfile` currently looks like this (wrong ❌):
```
FROM louislam/uptime-kuma:2.1.3
...
VOLUME ["/app/data"]
```     ← these backticks got included
```
# ## How It Works    ← and even markdown text!
```

The Docker parser hit the ` ``` ` on line 7 and didn't know what to do with it.

## Fix Steps

1. Go to your repo → find the `Dockerfile` in the root
2. Edit it and **delete everything except** the 4 lines above
3. Commit & push — the Action will re-run automatically

## Also — The Submodule Warning

You also have this error:
```
fatal: No url found for submodule path 'uptime-kuma' in .gitmodules