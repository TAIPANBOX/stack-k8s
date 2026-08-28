// Standard library only, deliberately. This guards the root of the tunnel, so
// its dependency list is a security property: nothing here is fetched, pinned
// or trusted beyond the Go toolchain the image already builds with.
module github.com/TAIPANBOX/stack-k8s/images/uapi-proxy

go 1.27
