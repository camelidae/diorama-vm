// Binary diorama-vm-vsockd relays guest vsock port 1024 to containerd's unix
// socket, giving the Mac host control without entering the VM.
//
// Guest:  vsock listen CID_ANY:1024 → dial /run/containerd/containerd.sock
// Host:   VZVirtioSocketDeviceConfiguration bridges artifacts/run/containerd.sock
//
//	to vsock port 1024 (see microvm/main.swift).
//
// Deliberately stdlib + x/sys/unix only (no third-party imports): every
// u-root command already links x/sys, so this adds no new dependency edge to
// the gobusybox image. Note the stdlib net package cannot wrap a vsock fd
// (FileListener fails in getsockname), so accepted fds are wrapped in a
// hand-rolled net.Conn below.
package main

import (
	"io"
	"log"
	"net"
	"time"

	"golang.org/x/sys/unix"
)

const (
	vsockPort      = 1024
	containerdSock = "/run/containerd/containerd.sock"
)

// vsockConn is a net.Conn over an already-accepted AF_VSOCK fd.
type vsockConn struct{ fd int }

func (c *vsockConn) Read(b []byte) (int, error)       { return unix.Read(c.fd, b) }
func (c *vsockConn) Write(b []byte) (int, error)      { return unix.Write(c.fd, b) }
func (c *vsockConn) Close() error                     { return unix.Close(c.fd) }
func (c *vsockConn) LocalAddr() net.Addr              { return vsockAddr("local") }
func (c *vsockConn) RemoteAddr() net.Addr             { return vsockAddr("remote") }
func (c *vsockConn) SetDeadline(time.Time) error      { return nil }
func (c *vsockConn) SetReadDeadline(time.Time) error  { return nil }
func (c *vsockConn) SetWriteDeadline(time.Time) error { return nil }

type vsockAddr string

func (a vsockAddr) Network() string { return "vsock" }
func (a vsockAddr) String() string  { return string(a) }

func main() {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("vsock socket: %v", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: vsockPort}); err != nil {
		log.Fatalf("vsock bind :%d: %v", vsockPort, err)
	}
	if err := unix.Listen(fd, 16); err != nil {
		log.Fatalf("vsock listen: %v", err)
	}
	log.Printf("diorama-vm-vsockd: relaying vsock :%d -> %s", vsockPort, containerdSock)
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go relay(&vsockConn{fd: nfd})
	}
}

func relay(vc net.Conn) {
	defer vc.Close()
	uc, err := net.Dial("unix", containerdSock)
	if err != nil {
		log.Printf("dial %s: %v", containerdSock, err)
		return
	}
	defer uc.Close()
	go func() {
		_, _ = io.Copy(uc, vc)
		_ = uc.(*net.UnixConn).CloseWrite()
	}()
	_, _ = io.Copy(vc, uc)
}
