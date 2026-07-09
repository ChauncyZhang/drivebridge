package feishu

import (
	"context"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/object"
)

func TestDriveItemModTime(t *testing.T) {
	item := driveItem{ModifiedTime: "1783261657", CreatedTime: "1"}
	got := item.modTime()
	want := time.Unix(1783261657, 0)
	if !got.Equal(want) {
		t.Fatalf("modTime = %v, want %v", got, want)
	}
}

func TestVirtualURLOpenRange(t *testing.T) {
	f := &Fs{name: "test", opt: Options{DocsAsURL: true}}
	o := f.newURLObject("doc.url", driveItem{
		Name:  "doc",
		Token: "doc-token",
		Type:  "docx",
		URL:   "https://example.feishu.cn/docx/doc-token",
	})
	rc, err := o.Open(context.Background(), &fs.RangeOption{Start: 10, End: 17})
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "hortcut]" {
		t.Fatalf("range content = %q", string(b))
	}
}

func TestDeleteType(t *testing.T) {
	f := &Fs{name: "test", opt: Options{DocsAsURL: true}}

	file := f.newObject("file.txt", driveItem{
		Name:  "file.txt",
		Token: "file-token",
		Type:  "file",
	}, false)
	if got := file.deleteType(); got != "file" {
		t.Fatalf("file delete type = %q, want file", got)
	}

	doc := f.newURLObject("doc.url", driveItem{
		Name:  "doc",
		Token: "doc-token",
		Type:  "docx",
		URL:   "https://example.feishu.cn/docx/doc-token",
	})
	if got := doc.deleteType(); got != "docx" {
		t.Fatalf("virtual doc delete type = %q, want docx", got)
	}
}

func TestLiveFeishuCLIBackend(t *testing.T) {
	folderToken := strings.TrimSpace(os.Getenv("RCLONE_FEISHU_TEST_FOLDER_TOKEN"))
	if folderToken == "" {
		t.Skip("set RCLONE_FEISHU_TEST_FOLDER_TOKEN to run live lark-cli tests")
	}
	command := strings.TrimSpace(os.Getenv("RCLONE_FEISHU_COMMAND"))
	if command == "" {
		command = defaultCommand
	}

	ctx := context.Background()
	fsys, err := NewFs(ctx, "feishu-live", "", configmap.Simple{
		"command":           command,
		"root_folder_token": folderToken,
	})
	if err != nil {
		t.Fatal(err)
	}

	const name = "rclone-live-test.txt"
	const moved = "rclone-live-test-renamed.txt"
	_ = cleanupLive(ctx, fsys, name)
	_ = cleanupLive(ctx, fsys, moved)

	missing, err := fsys.NewObject(ctx, "rclone-live-test-missing.txt")
	if err != fs.ErrorObjectNotFound {
		t.Fatalf("NewObject missing error = %v, want %v", err, fs.ErrorObjectNotFound)
	}
	if missing != nil {
		t.Fatalf("NewObject missing object = %#v, want nil", missing)
	}

	src := object.NewStaticObjectInfo(name, time.Now(), int64(len("hello feishu")), true, nil, fsys)
	obj, err := fsys.Put(ctx, strings.NewReader("hello feishu"), src)
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	rc, err := obj.Open(ctx)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	body, err := io.ReadAll(rc)
	_ = rc.Close()
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}
	if string(body) != "hello feishu" {
		t.Fatalf("downloaded body = %q", string(body))
	}

	mover, ok := fsys.(fs.Mover)
	if !ok {
		t.Fatal("backend does not implement fs.Mover")
	}
	movedObj, err := mover.Move(ctx, obj, moved)
	if err != nil {
		t.Fatalf("Move failed: %v", err)
	}
	if movedObj.Remote() != moved {
		t.Fatalf("moved remote = %q, want %q", movedObj.Remote(), moved)
	}
	if err := movedObj.Remove(ctx); err != nil {
		t.Fatalf("Remove failed: %v", err)
	}
}

func cleanupLive(ctx context.Context, fsys fs.Fs, remote string) error {
	obj, err := fsys.NewObject(ctx, remote)
	if err == fs.ErrorObjectNotFound {
		return nil
	}
	if err != nil {
		return err
	}
	return obj.Remove(ctx)
}
