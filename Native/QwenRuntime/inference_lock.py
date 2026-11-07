import contextlib,os,fcntl

@contextlib.contextmanager
def exclusive():
    path=os.environ.get('TALKTUCK_INFERENCE_LOCK')
    if not path:yield;return
    fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX);yield
    finally:os.close(fd)
