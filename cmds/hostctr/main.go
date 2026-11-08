package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
)

func must(err error, what string) {
	if err != nil {
		fmt.Printf("FAIL %s: %v\n", what, err)
		os.Exit(1)
	}
}

func runRemote(ctx context.Context, c *client.Client, id string, args []string) uint32 {
	img, err := c.GetImage(ctx, "docker.io/library/busybox:latest")
	must(err, "get image")
	ctx, done, err := c.WithLease(ctx)
	must(err, "lease")
	defer done(ctx)
	ctr, err := c.NewContainer(ctx, id,
		client.WithRuntime("io.containerd.runsc.v1", nil),
		client.WithSnapshotter("overlayfs"),
		client.WithNewSnapshot(id+"-snap", img),
		client.WithNewSpec(oci.WithDefaultSpecForPlatform("linux/arm64"), oci.WithImageConfig(img), oci.WithProcessArgs(args...)),
	)
	must(err, "new container "+id)
	defer ctr.Delete(ctx, client.WithSnapshotCleanup)
	t, err := ctr.NewTask(ctx, cio.NullIO)
	must(err, "new task "+id)
	defer t.Delete(ctx)
	waitCh, err := t.Wait(ctx)
	must(err, "wait "+id)
	must(t.Start(ctx), "start "+id)
	st := <-waitCh
	return st.ExitCode()
}

func main() {
	sock := os.Args[1]
	ctx := namespaces.WithNamespace(context.Background(), "default")
	c, err := client.New(sock)
	must(err, "dial")
	defer c.Close()
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	tag := fmt.Sprintf("%d", time.Now().UnixNano())
	v, err := c.Version(ctx)
	must(err, "version")
	fmt.Printf("server version=%s revision=%s\n", v.Version, v.Revision)
	imgs, err := c.ImageService().List(ctx)
	must(err, "list images")
	fmt.Printf("images=%d\n", len(imgs))
	for _, im := range imgs {
		fmt.Printf("  %s\n", im.Name)
	}
	rc := runRemote(ctx, c, "hostrun-true-"+tag, []string{"/bin/true"})
	fmt.Printf("remote /bin/true rc=%d\n", rc)
	rc2 := runRemote(ctx, c, "hostrun-false-"+tag, []string{"/bin/false"})
	fmt.Printf("remote /bin/false rc=%d\n", rc2)
	rc3 := runRemote(ctx, c, "hostrun-exit3-"+tag, []string{"/bin/sh", "-c", "exit 3"})
	fmt.Printf("remote exit-3 rc=%d\n", rc3)
	if rc != 0 || rc3 != 3 {
		fmt.Println("FAIL unexpected exit codes")
		os.Exit(1)
	}
	fmt.Println("HOST-RUN-OK")
}
