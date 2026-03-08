# Managing Docker Filesystem Command

```bash
# 1. See how much space Docker is eating
docker system df

# 2. Remove ALL build cache (failed + successful pip downloads, intermediate layers)
docker builder prune -af

# 3. Remove dangling images (failed/intermediate builds with no tag)
docker image prune -f

# 4. Remove stopped containers from failed builds
docker container prune -f

# 5. Nuclear option - remove EVERYTHING unused (images, containers, cache, networks)
docker system prune -af

# Check space recovered
docker system df
```

Recommended order:

- Start with `docker builder prune -af` - this is where most of the failed pip temp lives (BuildKit cache layers). The -a flag removes all cache, not just dangling.
- Then docker image `prune -f` - removes untagged intermediate images from failed builds.
- Only use `docker system prune -af` if you want a full reset (this also removes cached base images like pytorch/pytorch, so next build will re-pull them).
- If you're using `sudo docker`, prefix all commands with `sudo`.


## To remove everything not currently used by a running container:

```bash
# Remove ALL unused images (tagged + untagged) not used by running containers
docker image prune -af

# Or the full nuclear option - images, containers, build cache, networks
docker system prune -af
```

The key difference:

|Command	| What it removes |
|---|---|
| docker image prune -f	| Only dangling (untagged) images |
| docker image prune -af | All images not used by a running container |
| docker builder prune -af | All build cache layers |
| docker system prune -af | All of the above + stopped containers + unused networks |

So for maximum space recovery after failed builds:
```bash
# Run these on your build machine
docker builder prune -af    # clear build cache (biggest win)
docker image prune -af      # clear all unused images
docker container prune -f   # clear stopped containers
docker system df             # verify space recovered
```

The `-a` flag is what makes it remove unused-but-tagged images, not just dangling ones.