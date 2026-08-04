import requests,sys

with open(sys.argv[sys.argv.index("--file")+1],"rb") as f:
    r = requests.post(f"http://{sys.argv[sys.argv.index('--server')+1]}/upload",data={
        "token":sys.argv[sys.argv.index("--token")+1],
        "tag":sys.argv[sys.argv.index("--tag")+1],
        "psw":sys.argv[sys.argv.index("--psw")+1],
        "owner":"senlinjun",
        "repo":"NEk0"
    },files={"file":f})
    print(r.json())