OneDrive Free Client
====================

### Features:
* State caching
* Real-Time file monitoring with Inotify
* Resumable uploads

### What's missing:
* OneDrive for business is not supported
* While local changes are uploaded right away, remote changes are delayed.
* No GUI

### Dependencies
* [libcurl](http://curl.haxx.se/libcurl/)
* [SQLite 3](https://www.sqlite.org/) => 3.7.15
* [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

### Dependencies: Ubuntu
```
sudo apt-get install libcurl-dev
sudo apt-get install libsqlite3-dev
sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
wget -qO - http://dlang.org/d-keyring.gpg | sudo apt-key add -
sudo apt-get update && sudo apt-get install dmd-bin
```

### Dependencies: CentOS
Use the dmd spec file and build the Digital Mars D Compiler package. Utilise mock to rebuild the src.rpm for your environment, or use the src.rpm

```
sudo yum install sqlite-devel libcurl-devel
```

### Installation
1. `make`
2. `sudo make install`

### Configuration:
You should copy the default config file into your home directory before making changes:
```
mkdir -p ~/.config/onedrive
cp /usr/local/etc/onedrive.conf ~/.config/onedrive/config
```

Available options:
* `client_id`: application identifier necessary for the [authentication][2]
* `sync_dir`: directory where the files will be synced
* `skip_file`: any files that match this pattern will be skipped during sync
* `skip_dir`: any directories that match this pattern will be skipped during sync

Pattern are case insensitive.
`*` and `?` [wildcards characters][3] are supported.
Use `|` to separate multiple patterns.

[2]: https://dev.onedrive.com/auth/msa_oauth.htm
[3]: https://technet.microsoft.com/en-us/library/bb490639.aspx

### First run
The first time you run the program you will be asked to sign in. The procedure require a web browser.

### Service
If you want to sync your files automatically, enable and start the systemd service:
```
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the logs run:
```
journalctl --user-unit onedrive -f
```

### Usage:
```
Usage: onedrive [OPTION]...

no option    Validate configuration and exit.
                 --confdir Set the directory to use to store the configuration files.
        --create-directory Create a directory on OneDrive - no sync will be performed.
                   --debug Debug OneDrive HTTP communication.
   --destination-directory Destination directory for renamed or move on OneDrive - no sync will be performed.
               --directory Specify a single local directory within the OneDrive root to sync.
             --local-first Synchronize from the local directory source first, before downloading changes from OneDrive.
                  --logout Remove current user's OneDrive credentials.
                 --monitor Keep monitoring for local and remote changes.
                  --resync Forget the last saved state, perform a full sync.
        --remove-directory Remove a directory on OneDrive - no sync will be performed.
        --source-directory Source directory to rename or move on OneDrive - no sync will be performed.
             --synchronize Perform a synchronization
                 --verbose Print more details, useful for debugging.
-h                  --help This help information.
```

### Command Examples:

Sync your local onedrive home dir (~/OneDrive) and all sub directories (sync first from OneDrive -> Local)
```
onedrive --synchronize
```
Sync your local onedrive home dir (~/OneDrive) and all sub directories, resyncing (cleaning up any local DB cache issues, sync first from OneDrive -> Local)
```
onedrive --resync
```
Sync a specific local folder within your local onedrive home dir only (~/OneDrive/foldertosync) (sync first from OneDrive -> Local)
```
onedrive --synchronize --directory foldertosync
```
Sync a specific local folder within your local onedrive home dir only (~/OneDrive/foldertosync) (sync first from Local -> OneDrive)
```
onedrive --synchronize --directory foldertosync --local-first
```

Create a directory on Microsoft OneDrive (no sync is performed)
```
onedrive --create-directory newfolder             (create a parent)
onedrive --create-directory newfolder/1           (create a child in parent)
onedrive --create-directory totallynewtree/2      (create parent and child if parent does not exist)
```

Remove a directory on Microsoft OneDrive (no sync is performed)
```
onedrive --remove-directory newfolder             (remove parent and any children)
onedrive --create-directory newfolder/1           (remove child from parent)
```

Rename a directory on Microsoft OneDrive (no sync is performed)
```
onedrive --source-directory newfolder --destination-directory renamed
```

Move a directory on Microsoft OneDrive (no sync is performed)
```
onedrive --source-directory sourcefolder --destination-directory newlocation/sourcefolder     (if parent does not exist will be created)
```


### Notes:
* After changing the filters (`skip_file` or `skip_dir` in your configs) you must execute `onedrive --resync`
* [Windows naming conventions][4] apply
* Use `make debug` to generate an executable for debugging

[4]: https://msdn.microsoft.com/en-us/library/aa365247
