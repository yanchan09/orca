// SPDX-FileCopyrightText: 2024 yanchan09 <yan@omg.lol>
//
// SPDX-License-Identifier: MPL-2.0

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func main() {
	dir, err := os.MkdirTemp("", "orcavm-*")
	if err != nil {
		log.Fatalf("Failed to MkdirTemp: %v", err)
	}
	defer os.RemoveAll(dir)

	apiSocket := filepath.Join(dir, "firecracker-api.sock")
	vSocket := filepath.Join(dir, "v.sock")
	cmd := exec.Command("firecracker", "--api-sock", apiSocket)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Start(); err != nil {
		log.Fatalf("cmd.Start: %v", err)
	}

	delay := 10 * time.Millisecond
	for i := 0; i < 10; i++ {
		log.Printf("Waiting for Firecracker to boot (%d/%d)", i+1, 10)
		if _, err := os.Stat(apiSocket); err == nil {
			break
		}
		time.Sleep(delay)
		delay *= 2
	}

	apiClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return net.Dial("unix", apiSocket)
			},
		},
	}

	data, err := json.Marshal(struct {
		KernelImagePath string `json:"kernel_image_path"`
		BootArgs        string `json:"boot_args"`
		InitrdPath      string `json:"initrd_path"`
	}{
		KernelImagePath: "./crack/vmlinux",
		BootArgs:        "console=ttyS0 reboot=k panic=-1 quiet",
		InitrdPath:      "./crack/bootstrap.cpio",
	})
	if err != nil {
		log.Fatalf("json.Marshal: %v", err)
	}

	req, err := http.NewRequest(http.MethodPut, "http://localhost/boot-source", bytes.NewReader(data))
	if err != nil {
		log.Fatalf("http.NewRequest: %v", err)
	}
	resp, err := apiClient.Do(req)
	if err != nil {
		log.Fatalf("apiClient.Do: %v", err)
	}
	_ = resp.Body.Close()

	data, err = json.Marshal(struct {
		DriveId      string `json:"drive_id"`
		PathOnHost   string `json:"path_on_host"`
		IsReadOnly   bool   `json:"is_read_only"`
		IsRootDevice bool   `json:"is_root_device"`
	}{
		DriveId:    "root",
		PathOnHost: "./crack/postgres16-1.erofs",
		IsReadOnly: true,
	})
	if err != nil {
		log.Fatalf("json.Marshal: %v", err)
	}

	req, err = http.NewRequest(http.MethodPut, "http://localhost/drives/root", bytes.NewReader(data))
	if err != nil {
		log.Fatalf("http.NewRequest: %v", err)
	}
	resp, err = apiClient.Do(req)
	if err != nil {
		log.Fatalf("apiClient.Do: %v", err)
	}
	_ = resp.Body.Close()

	data, err = json.Marshal(struct {
		GuestCid int    `json:"guest_cid"`
		UdsPath  string `json:"uds_path"`
	}{
		GuestCid: 3,
		UdsPath:  vSocket,
	})
	if err != nil {
		log.Fatalf("json.Marshal: %v", err)
	}

	req, err = http.NewRequest(http.MethodPut, "http://localhost/vsock", bytes.NewReader(data))
	if err != nil {
		log.Fatalf("http.NewRequest: %v", err)
	}
	resp, err = apiClient.Do(req)
	if err != nil {
		log.Fatalf("apiClient.Do: %v", err)
	}
	_ = resp.Body.Close()

	go vsockServer(vSocket + "_1")

	data, err = json.Marshal(struct {
		ActionType string `json:"action_type"`
	}{
		ActionType: "InstanceStart",
	})
	if err != nil {
		log.Fatalf("json.Marshal: %v", err)
	}

	req, err = http.NewRequest(http.MethodPut, "http://localhost/actions", bytes.NewReader(data))
	if err != nil {
		log.Fatalf("http.NewRequest: %v", err)
	}
	resp, err = apiClient.Do(req)
	if err != nil {
		log.Fatalf("apiClient.Do: %v", err)
	}
	_ = resp.Body.Close()
	if err := cmd.Wait(); err != nil {
		log.Fatalf("cmd.Wait: %v", err)
	}
}

func vsockServer(path string) {
	l, err := net.Listen("unix", path)
	if err != nil {
		log.Fatalf("net.Listen: %v", err)
	}

	for {
		conn, err := l.Accept()
		if err != nil {
			log.Fatalf("l.Accept: %v", err)
		}

		for {
			header := make([]byte, 8)
			if _, err := io.ReadFull(conn, header); err != nil {
				log.Printf("conn.Read: %v", err)
				break
			}

			payloadSize := binary.LittleEndian.Uint32(header[4:8])
			payload := make([]byte, payloadSize)
			if _, err := io.ReadFull(conn, payload); err != nil {
				log.Printf("conn.Read: %v", err)
				break
			}

			if string(header[0:4]) == "HELO" {
				data, err := json.Marshal(struct {
					Argv []string `json:"argv"`
					Envp []string `json:"envp"`
				}{
					Argv: []string{
						"/usr/local/bin/docker-entrypoint.sh", "ps", "aux",
					},
					Envp: []string{
						"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
						"LANG=en_US.utf8",
						"PG_MAJOR=16",
						"PG_VERSION=16.1",
						"PG_SHA256=ce3c4d85d19b0121fe0d3f8ef1fa601f71989e86f8a66f7dc3ad546dd5564fec",
						"DOCKER_PG_LLVM_DEPS=llvm15-dev \t\tclang15",
						"PGDATA=/var/lib/postgresql/data",
						"POSTGRES_HOST_AUTH_METHOD=trust",
					},
				})
				if err != nil {
					log.Fatalf("json.Marshal: %v", err)
				}
				header := make([]byte, 8)
				copy(header[0:4], []byte("HELO"))
				binary.LittleEndian.PutUint32(header[4:8], uint32(len(data)))
				if _, err := conn.Write(header); err != nil {
					log.Printf("conn.Write: %v", err)
					break
				}
				if _, err := conn.Write(data); err != nil {
					log.Printf("conn.Write: %v", err)
					break
				}
			}
		}
	}
}
