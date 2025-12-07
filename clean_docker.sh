#!/bin/bash
echo "警告：此操作將刪除所有 Docker 容器、鏡像、卷和網絡！"
read -p "確定要繼續嗎？(y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    docker stop $(docker ps -aq) 2>/dev/null
    docker rm $(docker ps -aq) 2>/dev/null
    docker rmi $(docker images -q) 2>/dev/null
    docker volume rm $(docker volume ls -q) 2>/dev/null
    docker network rm $(docker network ls -q) 2>/dev/null
    docker system prune -a --volumes -f
    echo "Docker 清理完成。"
else
    echo "操作已取消。"
fi
