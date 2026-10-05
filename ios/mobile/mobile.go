// Package mobile is the gomobile binding surface for the iOS app. It wraps the
// upstream wiiudownloader package with a small, gomobile-safe API: no Go
// channels, no time.Time, no *http.Client and no non-byte slices cross the
// boundary. Nothing in the upstream package is modified here.
package mobile

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	wiiu "github.com/Xpl0itU/WiiUDownloader"
)

// Reporter mirrors the upstream ProgressReporter in a form gomobile can bind:
// Done() <-chan struct{} becomes Cancelled(), and time.Time becomes a Unix
// timestamp. The Swift bridge implements this protocol.
type Reporter interface {
	SetGameTitle(title string)
	UpdateDownloadProgress(downloaded int64, filename string)
	UpdateDecryptionProgress(progress float64)
	SetDownloadSize(size int64)
	ResetTotals()
	MarkFileAsDone(filename string)
	SetTotalDownloadedForFile(filename string, downloaded int64)
	SetStartTime(unixSeconds int64)
	Cancelled() bool
	WaitIfPaused() bool
}

// reporterAdapter bridges the gomobile Reporter to the upstream
// ProgressReporter + pauseAwareReporter interfaces.
type reporterAdapter struct {
	reporter Reporter

	done     chan struct{}
	stop     chan struct{}
	doneOnce sync.Once
}

func newReporterAdapter(r Reporter) *reporterAdapter {
	a := &reporterAdapter{
		reporter: r,
		done:     make(chan struct{}),
		stop:     make(chan struct{}),
	}
	go a.poll()
	return a
}

// poll closes done shortly after the reporter reports cancellation, so upstream
// wait loops can select on Done() without being able to poll Swift directly.
func (a *reporterAdapter) poll() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-a.stop:
			return
		case <-ticker.C:
			if a.reporter.Cancelled() {
				a.doneOnce.Do(func() { close(a.done) })
				return
			}
		}
	}
}

func (a *reporterAdapter) shutdown() {
	close(a.stop)
}

func (a *reporterAdapter) SetGameTitle(title string) { a.reporter.SetGameTitle(title) }

func (a *reporterAdapter) UpdateDownloadProgress(downloaded int64, filename string) {
	a.reporter.UpdateDownloadProgress(downloaded, filename)
}

func (a *reporterAdapter) UpdateDecryptionProgress(progress float64) {
	a.reporter.UpdateDecryptionProgress(progress)
}

func (a *reporterAdapter) Cancelled() bool { return a.reporter.Cancelled() }

// SetCancelled is never called by the library; cancellation originates in the
// Swift UI and is read back through Cancelled().
func (a *reporterAdapter) SetCancelled() {}

func (a *reporterAdapter) Done() <-chan struct{} { return a.done }

func (a *reporterAdapter) SetDownloadSize(size int64) { a.reporter.SetDownloadSize(size) }

func (a *reporterAdapter) ResetTotals() { a.reporter.ResetTotals() }

func (a *reporterAdapter) MarkFileAsDone(filename string) { a.reporter.MarkFileAsDone(filename) }

func (a *reporterAdapter) SetTotalDownloadedForFile(filename string, downloaded int64) {
	a.reporter.SetTotalDownloadedForFile(filename, downloaded)
}

func (a *reporterAdapter) SetStartTime(startTime time.Time) {
	a.reporter.SetStartTime(startTime.Unix())
}

func (a *reporterAdapter) WaitIfPaused() bool { return a.reporter.WaitIfPaused() }

// makeAdapter returns a ProgressReporter suitable for the upstream calls, along
// with a cleanup func. A nil reporter yields a nil ProgressReporter, which the
// upstream code already tolerates.
func makeAdapter(r Reporter) (wiiu.ProgressReporter, func()) {
	if r == nil {
		return nil, func() {}
	}
	a := newReporterAdapter(r)
	return a, a.shutdown
}

func newHTTPClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy: http.ProxyFromEnvironment,
			DialContext: (&net.Dialer{
				Timeout:   10 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			MaxIdleConns:          100,
			MaxIdleConnsPerHost:   8,
			MaxConnsPerHost:       16,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: 30 * time.Second,
			ExpectContinueTimeout: time.Second,
		},
	}
}

// titleEntryJSON mirrors the Swift TitleEntry encoding: titleID is a 16-digit
// hexadecimal string, the rest are numbers.
type titleEntryJSON struct {
	Name     string `json:"name"`
	TitleID  string `json:"titleID"`
	Region   uint8  `json:"region"`
	Key      uint8  `json:"key"`
	Category uint8  `json:"category"`
	Version  int    `json:"version"`
}

// SetTitleDatabase loads the title database JSON produced by the app and
// installs it in the upstream global database, so title keys and names resolve.
func SetTitleDatabase(jsonPath string) error {
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		return err
	}
	var raw []titleEntryJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	db := make([]wiiu.TitleEntry, 0, len(raw))
	for _, e := range raw {
		tid, err := strconv.ParseUint(e.TitleID, 16, 64)
		if err != nil {
			return errors.New("invalid title ID: " + e.TitleID)
		}
		db = append(db, wiiu.TitleEntry{
			Name:     e.Name,
			TitleID:  tid,
			Region:   e.Region,
			Key:      e.Key,
			Category: e.Category,
			Version:  e.Version,
		})
	}
	wiiu.SetTitleDatabase(db)
	return nil
}

// TitleInfo is the resolved header of a title's TMD.
type TitleInfo struct {
	TitleID      int64
	TitleVersion int64
}

// FetchTitleInfo downloads and parses a title's TMD header. version < 0 selects
// the latest version.
func FetchTitleInfo(titleID string, version int) (*TitleInfo, error) {
	tid, err := strconv.ParseUint(titleID, 16, 64)
	if err != nil {
		return nil, err
	}
	tmd, err := wiiu.FetchTitleTMD(tid, version, newHTTPClient())
	if err != nil {
		return nil, err
	}
	return &TitleInfo{TitleID: int64(tmd.TitleID), TitleVersion: int64(tmd.TitleVersion)}, nil
}

// DownloadTitle downloads a title via the upstream implementation. An empty
// decryptOutputDir decrypts in place.
func DownloadTitle(titleID, outputDir string, version int, doDecryption, deleteEncrypted bool, decryptOutputDir string, r Reporter) error {
	reporter, cleanup := makeAdapter(r)
	defer cleanup()
	return wiiu.DownloadTitleContents(titleID, outputDir, version, nil, doDecryption, reporter, deleteEncrypted, newHTTPClient(), decryptOutputDir)
}

// FileEntry is one file listed by a title's FST.
type FileEntry struct {
	Path      string
	Size      int64
	ContentID int64
	Offset    int64
	Length    int64
	Hashed    bool
	Shared    bool
}

// TitleFiles is a title's parsed file tree. Files are returned one at a time
// because gomobile cannot bind slices of structs.
type TitleFiles struct {
	inner *wiiu.TitleFileTree
}

// FetchTitleFiles downloads a title's FST and returns every file it lists.
func FetchTitleFiles(titleID string, version int) (*TitleFiles, error) {
	tid, err := strconv.ParseUint(titleID, 16, 64)
	if err != nil {
		return nil, err
	}
	tree, err := wiiu.FetchTitleFileTree(tid, version, newHTTPClient())
	if err != nil {
		return nil, err
	}
	return &TitleFiles{inner: tree}, nil
}

// FileCount is the number of files in the tree.
func (t *TitleFiles) FileCount() int {
	if t == nil || t.inner == nil {
		return 0
	}
	return len(t.inner.Files)
}

// FileAt returns the file at index, or nil when out of range.
func (t *TitleFiles) FileAt(index int) *FileEntry {
	if t == nil || t.inner == nil || index < 0 || index >= len(t.inner.Files) {
		return nil
	}
	f := t.inner.Files[index]
	return &FileEntry{
		Path:      f.Path,
		Size:      int64(f.Size),
		ContentID: int64(f.ContentID),
		Offset:    int64(f.Offset),
		Length:    int64(f.Length),
		Hashed:    f.Hashed,
		Shared:    f.Shared,
	}
}

// DownloadFiles fetches the contents the selected paths need and extracts them
// under outputDir. pathsJSON is a JSON array of path strings (gomobile cannot
// bind []string).
func (t *TitleFiles) DownloadFiles(outputDir, pathsJSON string, r Reporter) error {
	if t == nil || t.inner == nil {
		return errors.New("no title file tree")
	}
	var paths []string
	if err := json.Unmarshal([]byte(pathsJSON), &paths); err != nil {
		return err
	}
	reporter, cleanup := makeAdapter(r)
	defer cleanup()
	return t.inner.DownloadFiles(outputDir, paths, reporter)
}

// Close removes the temporary working set backing the tree.
func (t *TitleFiles) Close() error {
	if t == nil || t.inner == nil {
		return nil
	}
	err := t.inner.Close()
	t.inner = nil
	return err
}
