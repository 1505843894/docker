#!/bin/bash

# 设置颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 配置参数
DOCKER_USERNAME="1505843894"
DOCKER_PASSWORD="Zrx1505843894"
BACKUP_DIR="/tmp/docker_backup"
DATE_TAG=$(date +%Y%m%d)
VOLUME_BACKUP_DIR="$BACKUP_DIR/volumes"
PANEL_BACKUP_DIR="$BACKUP_DIR/1panel"
PANEL_DIR="/www/1panel"  # 1panel安装目录，可能需要根据实际情况调整

# 创建备份目录
mkdir -p "$BACKUP_DIR"
mkdir -p "$VOLUME_BACKUP_DIR"
mkdir -p "$PANEL_BACKUP_DIR"

# 输出带颜色的消息
log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

log_question() {
    echo -e "${BLUE}[选择]${NC} $1"
}

# 将字符串转换为小写
to_lowercase() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# 登录 Docker Hub
login_docker_hub() {
    log_info "登录 Docker Hub..."
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

    if [ $? -ne 0 ]; then
        log_error "Docker Hub 登录失败，请检查用户名和密码"
        exit 1
    fi
}

# 备份Docker容器
backup_containers() {
    # 获取所有运行中的容器
    log_info "获取所有运行中的容器..."
    CONTAINERS=$(docker ps --format "{{.Names}}")

    if [ -z "$CONTAINERS" ]; then
        log_warning "未找到运行中的容器"
        return
    fi

    # 备份计数器
    BACKUP_COUNT=0
    SUCCESS_COUNT=0

    # 遍历容器进行备份
    for CONTAINER in $CONTAINERS; do
        ((BACKUP_COUNT++))
        log_info "正在备份容器 [$BACKUP_COUNT]: $CONTAINER"
        
        # 为每个容器创建单独的工作目录
        CONTAINER_DIR="$BACKUP_DIR/$CONTAINER"
        mkdir -p "$CONTAINER_DIR"
        
        # 获取容器镜像信息
        CONTAINER_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
        log_info "容器 $CONTAINER 使用的镜像: $CONTAINER_IMAGE"
        
        # 获取容器端口映射和环境变量
        docker inspect "$CONTAINER" > "$CONTAINER_DIR/container_config.json"
        
        # 备份容器相关的卷
        backup_container_volumes "$CONTAINER" "$CONTAINER_DIR"
        
        # 导出容器
        log_info "导出容器 $CONTAINER 的数据..."
        if docker export "$CONTAINER" > "$CONTAINER_DIR/container.tar"; then
            # 检查导出的文件大小
            EXPORT_SIZE=$(du -h "$CONTAINER_DIR/container.tar" | cut -f1)
            log_info "导出成功: $EXPORT_SIZE"
            
            # 创建Dockerfile
            cat > "$CONTAINER_DIR/Dockerfile" << EOF
FROM scratch
ADD container.tar /
EOF
            
            # 备份镜像名称 - 将容器名转为小写
            CONTAINER_LOWERCASE=$(to_lowercase "$CONTAINER")
            BACKUP_IMAGE_NAME="$DOCKER_USERNAME/backup-$CONTAINER_LOWERCASE:$DATE_TAG"
            
            # 记录原始容器名称和小写名称的映射关系
            echo "$CONTAINER" > "$CONTAINER_DIR/original_name.txt"
            
            # 构建备份镜像
            log_info "构建镜像: $BACKUP_IMAGE_NAME"
            cd "$CONTAINER_DIR"
            if docker build -t "$BACKUP_IMAGE_NAME" .; then
                # 推送到 Docker Hub
                log_info "推送镜像 $BACKUP_IMAGE_NAME 到 Docker Hub..."
                if docker push "$BACKUP_IMAGE_NAME"; then
                    log_info "镜像 $BACKUP_IMAGE_NAME 推送成功!"
                    ((SUCCESS_COUNT++))
                else
                    log_error "镜像 $BACKUP_IMAGE_NAME 推送失败"
                fi
            else
                log_error "构建镜像 $BACKUP_IMAGE_NAME 失败"
            fi
        else
            log_error "导出容器 $CONTAINER 失败"
        fi
        
        # 清理工作目录
        log_info "清理临时文件..."
        rm -rf "$CONTAINER_DIR"
    done

    # 保存容器列表和名称映射
    log_info "保存容器信息..."
    CONTAINERS_INFO="$BACKUP_DIR/containers_info.txt"
    CONTAINERS_MAP="$BACKUP_DIR/containers_map.txt"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" > "$CONTAINERS_INFO"
    
    # 创建容器名称映射文件
    for CONTAINER in $CONTAINERS; do
        CONTAINER_LOWERCASE=$(to_lowercase "$CONTAINER")
        echo "$CONTAINER:$CONTAINER_LOWERCASE" >> "$CONTAINERS_MAP"
    done

    # 创建容器信息镜像
    log_info "创建容器信息镜像..."
    mkdir -p "$BACKUP_DIR/info"
    cp "$CONTAINERS_INFO" "$BACKUP_DIR/info/"
    cp "$CONTAINERS_MAP" "$BACKUP_DIR/info/"
    cat > "$BACKUP_DIR/info/Dockerfile" << EOF
FROM alpine:latest
COPY containers_info.txt /backup/
COPY containers_map.txt /backup/
CMD ["cat", "/backup/containers_info.txt"]
EOF

    # 构建并推送容器信息镜像
    cd "$BACKUP_DIR/info"
    INFO_IMAGE_NAME="$DOCKER_USERNAME/docker-containers-info:$DATE_TAG"
    if docker build -t "$INFO_IMAGE_NAME" .; then
        docker push "$INFO_IMAGE_NAME"
        log_info "容器信息镜像推送成功: $INFO_IMAGE_NAME"
    else
        log_error "构建容器信息镜像失败"
    fi
    
    # 推送卷数据备份
    backup_volumes

    # 总结
    log_info "备份完成！共备份 $BACKUP_COUNT 个容器，成功 $SUCCESS_COUNT 个"
    if [ $BACKUP_COUNT -ne $SUCCESS_COUNT ]; then
        log_warning "有 $(($BACKUP_COUNT - $SUCCESS_COUNT)) 个容器备份失败"
    fi

    log_info "备份镜像可通过以下方式恢复:"
    log_info "1. 拉取镜像: docker pull $DOCKER_USERNAME/backup-容器名小写:$DATE_TAG"
    log_info "2. 从镜像创建容器: docker run -d [端口映射等参数] $DOCKER_USERNAME/backup-容器名小写:$DATE_TAG"
    log_info "3. 查看备份的容器列表: docker run --rm $INFO_IMAGE_NAME"
    log_info "4. 卷数据已备份为: $DOCKER_USERNAME/docker-volumes:$DATE_TAG"
}

# 备份容器关联的卷
backup_container_volumes() {
    local CONTAINER=$1
    local CONTAINER_DIR=$2
    
    log_info "检查容器 $CONTAINER 使用的卷..."
    
    # 获取容器使用的卷列表
    local VOLUMES=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}}{{println}}{{end}}{{end}}' "$CONTAINER")
    
    if [ -z "$VOLUMES" ]; then
        log_info "容器 $CONTAINER 没有使用卷"
        return
    fi
    
    # 创建卷记录文件
    echo "$VOLUMES" > "$CONTAINER_DIR/volumes.txt"
    log_info "容器 $CONTAINER 使用的卷已记录到文件"
    
    # 记录卷所属容器，用于后续备份
    while IFS=: read -r VOL_NAME VOL_DEST; do
        echo "$CONTAINER:$VOL_DEST" >> "$VOLUME_BACKUP_DIR/$VOL_NAME.info"
        echo "$VOL_NAME" >> "$VOLUME_BACKUP_DIR/volume_list.txt"
    done <<< "$VOLUMES"
}

# 备份所有卷数据
backup_volumes() {
    if [ ! -f "$VOLUME_BACKUP_DIR/volume_list.txt" ]; then
        log_info "没有需要备份的卷数据"
        return
    fi
    
    log_info "开始备份卷数据..."
    
    # 获取唯一的卷名列表
    local UNIQUE_VOLUMES=$(sort -u "$VOLUME_BACKUP_DIR/volume_list.txt")
    
    # 创建一个临时容器来备份卷数据
    local VOLUMES_TO_MOUNT=""
    for VOL_NAME in $UNIQUE_VOLUMES; do
        VOLUMES_TO_MOUNT="$VOLUMES_TO_MOUNT -v $VOL_NAME:/backup/$VOL_NAME"
    done
    
    # 创建临时容器
    log_info "创建临时容器来备份卷数据..."
    docker run --name volume-backup -d $VOLUMES_TO_MOUNT alpine sleep 3600
    
    # 备份每个卷
    for VOL_NAME in $UNIQUE_VOLUMES; do
        log_info "备份卷 $VOL_NAME..."
        docker exec volume-backup tar -czf "/backup/$VOL_NAME.tar.gz" -C "/backup/$VOL_NAME" .
        docker cp "volume-backup:/backup/$VOL_NAME.tar.gz" "$VOLUME_BACKUP_DIR/"
    done
    
    # 停止并删除临时容器
    docker stop volume-backup
    docker rm volume-backup
    
    # 创建卷备份镜像
    log_info "创建卷备份镜像..."
    cat > "$VOLUME_BACKUP_DIR/Dockerfile" << EOF
FROM alpine:latest
WORKDIR /backup
EOF

    # 复制卷数据和信息文件
    cd "$VOLUME_BACKUP_DIR"
    for VOL_NAME in $UNIQUE_VOLUMES; do
        echo "COPY $VOL_NAME.tar.gz ." >> Dockerfile
        echo "COPY $VOL_NAME.info ." >> Dockerfile
    done
    
    # 添加恢复脚本
    cat >> "$VOLUME_BACKUP_DIR/restore_volumes.sh" << 'EOF'
#!/bin/sh
mkdir -p /restored
for tar_file in *.tar.gz; do
    volume_name=${tar_file%.tar.gz}
    echo "Restoring volume $volume_name..."
    mkdir -p "/restored/$volume_name"
    tar -xzf "$tar_file" -C "/restored/$volume_name"
done
echo "All volumes restored to /restored directory"
EOF

    chmod +x "$VOLUME_BACKUP_DIR/restore_volumes.sh"
    echo "COPY restore_volumes.sh ." >> Dockerfile
    echo "CMD [\"/bin/sh\"]" >> Dockerfile
    
    # 构建并推送卷备份镜像
    VOLUMES_IMAGE_NAME="$DOCKER_USERNAME/docker-volumes:$DATE_TAG"
    docker build -t "$VOLUMES_IMAGE_NAME" .
    docker push "$VOLUMES_IMAGE_NAME"
    log_info "卷备份镜像推送成功: $VOLUMES_IMAGE_NAME"
}

# 从Docker Hub恢复容器
restore_containers() {
    log_info "正在从Docker Hub获取可用的备份..."
    
    # 使用更可靠的方式获取用户所有备份镜像
    log_info "获取您在Docker Hub上的所有备份镜像..."
    # 先登录确保有权限
    login_docker_hub
    
    # 获取所有backup-前缀的镜像仓库
    local BACKUP_REPOS=$(curl -s -H "Authorization: Bearer $(docker --config ~/.docker/ config inspect -f '{{.AuthConfigs}}' | grep -o '"auth":"[^"]*"' | head -1 | cut -d'"' -f4 | base64 -d | cut -d':' -f2)" "https://hub.docker.com/v2/repositories/$DOCKER_USERNAME/?page_size=100" | grep -o "\"name\":\"backup-[^\"]*\"" | cut -d'"' -f4 || echo "")
    
    # 如果上面的方法失败，尝试直接使用search
    if [ -z "$BACKUP_REPOS" ]; then
        log_info "尝试替代方法获取备份..."
        BACKUP_REPOS=$(docker search "$DOCKER_USERNAME/backup-" --format "{{.Name}}" | cut -d'/' -f2 | cut -d':' -f1 || echo "")
    fi
    
    # 获取卷备份和信息镜像
    local VOLUME_IMAGES=$(docker search "$DOCKER_USERNAME/docker-volumes" --format "{{.Name}}" | sort -r)
    local ALL_BACKUPS=""
    
    # 如果找不到任何备份
    if [ -z "$BACKUP_REPOS" ]; then
        log_error "找不到任何备份镜像，无法恢复"
        log_info "请确保您的Docker Hub账号中有备份镜像"
        return
    fi
    
    # 为每个备份仓库获取所有标签（版本）
    for repo in $BACKUP_REPOS; do
        log_info "获取 $repo 的所有版本..."
        local TAGS=$(curl -s "https://hub.docker.com/v2/repositories/$DOCKER_USERNAME/$repo/tags/?page_size=100" | grep -o "\"name\":\"[^\"]*\"" | cut -d'"' -f4 || echo "")
        
        for tag in $TAGS; do
            ALL_BACKUPS="$ALL_BACKUPS$DOCKER_USERNAME/$repo:$tag"$'\n'
        done
    done
    
    # 如果还是空的，显示错误
    if [ -z "$ALL_BACKUPS" ]; then
        log_error "无法获取备份镜像的详细信息"
        log_info "正在尝试直接从本地获取信息..."
        
        # 尝试从本地Docker镜像获取信息
        ALL_BACKUPS=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "$DOCKER_USERNAME/backup-" || echo "")
        
        if [ -z "$ALL_BACKUPS" ]; then
            log_error "找不到任何备份镜像，无法恢复"
            return
        fi
    fi
    
    # 显示备份列表
    log_info "找到以下备份镜像:"
    echo "$ALL_BACKUPS" | sort -r
    
    # 询问恢复方式
    log_question "请选择恢复方式:"
    echo "1) 恢复单个容器"
    echo "2) 一键恢复所有容器"
    read RESTORE_MODE
    
    if [ "$RESTORE_MODE" = "2" ]; then
        restore_all_containers "$ALL_BACKUPS" "$VOLUME_IMAGES"
    else
        restore_single_container "$ALL_BACKUPS" "$VOLUME_IMAGES"
    fi
}

# 恢复单个容器
restore_single_container() {
    local ALL_BACKUPS=$1
    local VOLUME_IMAGES=$2
    
    # 首先显示可恢复的容器名称列表
    log_info "可恢复的容器列表:"
    local CONTAINER_NAMES=$(echo "$ALL_BACKUPS" | sed -E "s|$DOCKER_USERNAME/backup-([^:]+):.*|\1|" | sort -u)
    
    local counter=1
    local containers_array=()
    
    while read -r container; do
        if [ -n "$container" ]; then
            echo "$counter) $container"
            containers_array+=("$container")
            ((counter++))
        fi
    done <<< "$CONTAINER_NAMES"
    
    if [ ${#containers_array[@]} -eq 0 ]; then
        log_error "无法解析容器名称列表"
        return
    fi
    
    # 询问要恢复的容器
    log_question "请选择要恢复的容器 (1-$((counter-1))):"
    read CONTAINER_CHOICE
    
    if ! [[ "$CONTAINER_CHOICE" =~ ^[0-9]+$ ]] || [ "$CONTAINER_CHOICE" -lt 1 ] || [ "$CONTAINER_CHOICE" -gt $((counter-1)) ]; then
        log_error "无效的选择，恢复取消"
        return
    fi
    
    local CONTAINER_TO_RESTORE="${containers_array[$((CONTAINER_CHOICE-1))]}"
    log_info "将恢复容器: $CONTAINER_TO_RESTORE"
    
    # 显示所选容器的可用版本
    local CONTAINER_BACKUPS=$(echo "$ALL_BACKUPS" | grep "backup-$CONTAINER_TO_RESTORE:" | sort -r)
    
    counter=1
    local backup_array=()
    
    while read -r backup; do
        if [ -n "$backup" ]; then
            echo "$counter) $backup"
            backup_array+=("$backup")
            ((counter++))
        fi
    done <<< "$CONTAINER_BACKUPS"
    
    if [ ${#backup_array[@]} -eq 0 ]; then
        log_error "无法获取容器 $CONTAINER_TO_RESTORE 的备份版本"
        return
    fi
    
    # 询问要使用的备份版本
    log_question "请选择要恢复的备份版本 (1-$((counter-1))):"
    read VERSION_CHOICE
    
    if ! [[ "$VERSION_CHOICE" =~ ^[0-9]+$ ]] || [ "$VERSION_CHOICE" -lt 1 ] || [ "$VERSION_CHOICE" -gt $((counter-1)) ]; then
        log_error "无效的选择，恢复取消"
        return
    fi
    
    local SELECTED_BACKUP="${backup_array[$((VERSION_CHOICE-1))]}"
    log_info "将使用 $SELECTED_BACKUP 进行恢复"
    
    # 询问端口映射
    log_question "请输入端口映射 (例如: -p 80:80 -p 443:443) 或直接按回车使用默认值:"
    read PORT_MAPPING
    
    # 询问容器名称
    log_question "请输入新容器的名称 (默认: $CONTAINER_TO_RESTORE):"
    read NEW_CONTAINER_NAME
    
    if [ -z "$NEW_CONTAINER_NAME" ]; then
        NEW_CONTAINER_NAME="$CONTAINER_TO_RESTORE"
    fi
    
    restore_container "$SELECTED_BACKUP" "$NEW_CONTAINER_NAME" "$PORT_MAPPING" "$VOLUME_IMAGES"
}

# 一键恢复所有容器
restore_all_containers() {
    local ALL_BACKUPS=$1
    local VOLUME_IMAGES=$2
    
    log_info "正在获取最新的备份版本..."
    
    # 提取唯一的容器名称
    local UNIQUE_CONTAINERS=($(echo "$ALL_BACKUPS" | sed -E "s|$DOCKER_USERNAME/backup-([^:]+):.*|\1|" | sort -u))
    local LATEST_BACKUPS=()
    
    # 为每个容器找到最新的备份
    for container in "${UNIQUE_CONTAINERS[@]}"; do
        if [ -n "$container" ]; then
            # 获取该容器的最新备份（按版本号排序）
            local latest=$(echo "$ALL_BACKUPS" | grep "backup-$container:" | sort -r | head -1)
            if [ -n "$latest" ]; then
                LATEST_BACKUPS+=("$latest")
            fi
        fi
    done
    
    # 显示找到的容器
    log_info "找到以下容器的最新备份:"
    for i in "${!UNIQUE_CONTAINERS[@]}"; do
        echo "$((i+1))) ${UNIQUE_CONTAINERS[$i]} -> ${LATEST_BACKUPS[$i]}"
    done
    
    log_question "是否恢复所有上述容器? (y/n)"
    read CONFIRM
    
    if [ "$CONFIRM" != "y" ]; then
        log_info "取消恢复操作"
        return
    fi
    
    # 恢复卷数据（一次性恢复）
    if [ -n "$VOLUME_IMAGES" ]; then
        log_question "是否需要恢复卷数据? (y/n)"
        read RESTORE_VOLUMES
        
        if [ "$RESTORE_VOLUMES" = "y" ]; then
            # 拉取最新的卷备份镜像
            local LATEST_VOLUME_IMAGE=$(echo "$VOLUME_IMAGES" | head -n 1)
            log_info "从 $LATEST_VOLUME_IMAGE 恢复卷数据..."
            docker pull "$LATEST_VOLUME_IMAGE"
            
            # 创建临时容器来恢复卷数据
            docker run --name volume-restore "$LATEST_VOLUME_IMAGE" /restore_volumes.sh
            
            # 从恢复的卷中提取数据
            docker cp volume-restore:/restored ./restored_volumes
            docker rm volume-restore
            
            log_info "卷数据已恢复到 ./restored_volumes 目录"
            log_info "您可以手动将这些数据移动到适当的位置，或者在创建新容器时使用 -v 参数挂载这些目录"
        fi
    fi
    
    # 逐个恢复容器
    local SUCCESS_COUNT=0
    
    for i in "${!LATEST_BACKUPS[@]}"; do
        local backup="${LATEST_BACKUPS[$i]}"
        local container_name="${UNIQUE_CONTAINERS[$i]}"
        
        log_info "正在恢复容器 ($((i+1))/${#LATEST_BACKUPS[@]}): $container_name"
        
        # 检查是否存在同名容器
        if docker ps -a --format "{{.Names}}" | grep -q "\<$container_name\>"; then
            log_warning "已存在同名容器 $container_name"
            log_question "是否删除已有容器? (y/n)"
            read DELETE_EXISTING
            
            if [ "$DELETE_EXISTING" = "y" ]; then
                log_info "删除容器 $container_name..."
                docker stop "$container_name" 2>/dev/null
                docker rm "$container_name"
            else
                log_warning "跳过恢复容器 $container_name"
                continue
            fi
        fi
        
        # 恢复容器，不设置端口映射（需要手动配置）
        if restore_container "$backup" "$container_name" "" ""; then
            ((SUCCESS_COUNT++))
        fi
    done
    
    log_info "一键恢复完成！成功恢复 $SUCCESS_COUNT/${#LATEST_BACKUPS[@]} 个容器"
    if [ $SUCCESS_COUNT -ne ${#LATEST_BACKUPS[@]} ]; then
        log_warning "有 $((${#LATEST_BACKUPS[@]} - SUCCESS_COUNT)) 个容器恢复失败"
    fi
}

# 恢复单个容器的功能函数
restore_container() {
    local SELECTED_BACKUP=$1
    local NEW_CONTAINER_NAME=$2
    local PORT_MAPPING=$3
    local VOLUME_IMAGES=$4
    
    # 检查是否存在同名容器
    if docker ps -a --format "{{.Names}}" | grep -q "^${NEW_CONTAINER_NAME}$"; then
        log_warning "已存在同名容器 $NEW_CONTAINER_NAME"
        log_question "是否删除已有容器? (y/n)"
        read DELETE_EXISTING
        
        if [ "$DELETE_EXISTING" = "y" ]; then
            log_info "删除容器 $NEW_CONTAINER_NAME..."
            docker stop "$NEW_CONTAINER_NAME" 2>/dev/null
            docker rm "$NEW_CONTAINER_NAME"
        else
            log_error "无法继续恢复，因为同名容器已存在"
            return 1
        fi
    fi
    
    # 如果是单容器恢复时才检查是否需要恢复卷
    if [ -n "$VOLUME_IMAGES" ] && [ -n "$4" ]; then
        log_question "是否需要恢复卷数据? (y/n)"
        read RESTORE_VOLUMES
        
        if [ "$RESTORE_VOLUMES" = "y" ]; then
            # 拉取最新的卷备份镜像
            local LATEST_VOLUME_IMAGE=$(echo "$VOLUME_IMAGES" | head -n 1)
            log_info "从 $LATEST_VOLUME_IMAGE 恢复卷数据..."
            docker pull "$LATEST_VOLUME_IMAGE"
            
            # 创建临时容器来恢复卷数据
            docker run --name volume-restore "$LATEST_VOLUME_IMAGE" /restore_volumes.sh
            
            # 从恢复的卷中提取数据
            docker cp volume-restore:/restored ./restored_volumes
            docker rm volume-restore
            
            log_info "卷数据已恢复到 ./restored_volumes 目录"
            log_info "您可以手动将这些数据移动到适当的位置，或者在创建新容器时使用 -v 参数挂载这些目录"
        fi
    fi
    
    # 拉取备份镜像
    log_info "拉取备份镜像 $SELECTED_BACKUP..."
    docker pull "$SELECTED_BACKUP"
    
    # 创建新容器
    log_info "从备份创建新容器 $NEW_CONTAINER_NAME..."
    local RUN_CMD="docker run -d $PORT_MAPPING --name $NEW_CONTAINER_NAME $SELECTED_BACKUP"
    log_info "执行命令: $RUN_CMD"
    eval "$RUN_CMD"
    
    if [ $? -eq 0 ]; then
        log_info "容器 $NEW_CONTAINER_NAME 已成功从备份创建"
        log_info "可以使用 'docker logs $NEW_CONTAINER_NAME' 查看容器日志"
        log_info "可以使用 'docker exec -it $NEW_CONTAINER_NAME sh' 进入容器"
        return 0
    else
        log_error "容器创建失败，请检查错误信息"
        return 1
    fi
}

# 备份1panel面板数据
backup_1panel() {
    log_info "开始备份1panel面板数据..."
    
    # 检查1panel目录是否存在
    if [ ! -d "$PANEL_DIR" ]; then
        log_warning "未找到1panel安装目录: $PANEL_DIR"
        log_question "请输入1panel安装目录路径:"
        read CUSTOM_PANEL_DIR
        
        if [ -z "$CUSTOM_PANEL_DIR" ]; then
            log_error "未指定1panel目录，无法备份"
            return
        fi
        
        PANEL_DIR="$CUSTOM_PANEL_DIR"
        
        if [ ! -d "$PANEL_DIR" ]; then
            log_error "指定的目录不存在: $PANEL_DIR"
            return
        fi
    fi
    
    # 检查网站目录
    WEBSITES_DIR="$PANEL_DIR/www"
    if [ ! -d "$WEBSITES_DIR" ]; then
        log_warning "未找到1panel网站目录: $WEBSITES_DIR"
        log_question "请输入1panel网站目录路径:"
        read CUSTOM_WEBSITES_DIR
        
        if [ -z "$CUSTOM_WEBSITES_DIR" ]; then
            log_error "未指定网站目录，无法备份"
            return
        fi
        
        WEBSITES_DIR="$CUSTOM_WEBSITES_DIR"
        
        if [ ! -d "$WEBSITES_DIR" ]; then
            log_error "指定的网站目录不存在: $WEBSITES_DIR"
            return
        fi
    fi
    
    # 备份网站配置
    log_info "备份1panel网站配置..."
    tar -czf "$PANEL_BACKUP_DIR/websites.tar.gz" -C "$PANEL_DIR" www 2>/dev/null
    
    # 检查备份是否成功
    if [ $? -ne 0 ]; then
        log_error "备份网站配置失败"
        return
    fi
    
    # 备份nginx配置
    NGINX_DIR="$PANEL_DIR/nginx"
    if [ -d "$NGINX_DIR" ]; then
        log_info "备份Nginx配置..."
        tar -czf "$PANEL_BACKUP_DIR/nginx.tar.gz" -C "$PANEL_DIR" nginx 2>/dev/null
    fi
    
    # 备份数据库配置
    DB_DIR="$PANEL_DIR/mysql"
    if [ -d "$DB_DIR" ]; then
        log_info "备份数据库配置..."
        tar -czf "$PANEL_BACKUP_DIR/mysql.tar.gz" -C "$PANEL_DIR" mysql 2>/dev/null
    fi
    
    # 创建1panel备份镜像
    log_info "创建1panel备份镜像..."
    cd "$PANEL_BACKUP_DIR"
    
    # 创建Dockerfile
    cat > "$PANEL_BACKUP_DIR/Dockerfile" << EOF
FROM alpine:latest
WORKDIR /backup
EOF
    
    # 添加备份文件
    if [ -f "$PANEL_BACKUP_DIR/websites.tar.gz" ]; then
        echo "COPY websites.tar.gz /backup/" >> Dockerfile
    fi
    
    if [ -f "$PANEL_BACKUP_DIR/nginx.tar.gz" ]; then
        echo "COPY nginx.tar.gz /backup/" >> Dockerfile
    fi
    
    if [ -f "$PANEL_BACKUP_DIR/mysql.tar.gz" ]; then
        echo "COPY mysql.tar.gz /backup/" >> Dockerfile
    fi
    
    # 添加恢复脚本
    cat > "$PANEL_BACKUP_DIR/restore_panel.sh" << 'EOF'
#!/bin/sh
mkdir -p /restored
cd /restored

if [ -f "/backup/websites.tar.gz" ]; then
    echo "正在恢复网站数据..."
    tar -xzf /backup/websites.tar.gz
fi

if [ -f "/backup/nginx.tar.gz" ]; then
    echo "正在恢复Nginx配置..."
    tar -xzf /backup/nginx.tar.gz
fi

if [ -f "/backup/mysql.tar.gz" ]; then
    echo "正在恢复数据库配置..."
    tar -xzf /backup/mysql.tar.gz
fi

echo "所有1panel数据已恢复到 /restored 目录"
EOF
    
    chmod +x "$PANEL_BACKUP_DIR/restore_panel.sh"
    echo "COPY restore_panel.sh /backup/" >> Dockerfile
    echo "CMD [\"/bin/sh\"]" >> Dockerfile
    
    # 构建并推送镜像
    PANEL_IMAGE_NAME="$DOCKER_USERNAME/panel-backup:$DATE_TAG"
    
    if docker build -t "$PANEL_IMAGE_NAME" .; then
        log_info "推送1panel备份镜像: $PANEL_IMAGE_NAME"
        
        if docker push "$PANEL_IMAGE_NAME"; then
            log_info "1panel备份镜像推送成功: $PANEL_IMAGE_NAME"
        else
            log_error "1panel备份镜像推送失败"
        fi
    else
        log_error "构建1panel备份镜像失败"
    fi
    
    log_info "1panel面板数据备份完成"
}

# 恢复1panel面板数据
restore_1panel() {
    log_info "正在从Docker Hub获取可用的1panel备份..."
    
    # 获取所有1panel备份镜像
    local PANEL_IMAGES=$(docker search "$DOCKER_USERNAME/panel-backup" --format "{{.Name}}" | sort -r)
    
    if [ -z "$PANEL_IMAGES" ]; then
        log_error "没有找到1panel备份镜像，无法恢复"
        return
    fi
    
    # 显示可用的备份版本
    log_info "找到以下1panel备份版本:"
    local counter=1
    local backup_array=()
    
    while read -r backup; do
        echo "$counter) $backup"
        backup_array+=("$backup")
        ((counter++))
    done <<< "$PANEL_IMAGES"
    
    # 询问要使用的备份版本
    log_question "请选择要恢复的备份版本 (1-$((counter-1))):"
    read VERSION_CHOICE
    
    if ! [[ "$VERSION_CHOICE" =~ ^[0-9]+$ ]] || [ "$VERSION_CHOICE" -lt 1 ] || [ "$VERSION_CHOICE" -gt $((counter-1)) ]; then
        log_error "无效的选择，恢复取消"
        return
    fi
    
    local SELECTED_BACKUP="${backup_array[$((VERSION_CHOICE-1))]}"
    log_info "将使用 $SELECTED_BACKUP 进行恢复"
    
    # 询问恢复路径
    log_question "请输入1panel安装目录路径 (默认: $PANEL_DIR):"
    read RESTORE_DIR
    
    if [ -z "$RESTORE_DIR" ]; then
        RESTORE_DIR="$PANEL_DIR"
    fi
    
    # 检查目标目录
    if [ ! -d "$RESTORE_DIR" ]; then
        log_warning "目标目录不存在: $RESTORE_DIR"
        log_question "是否创建该目录? (y/n)"
        read CREATE_DIR
        
        if [ "$CREATE_DIR" = "y" ]; then
            mkdir -p "$RESTORE_DIR"
        else
            log_error "无法继续恢复，因为目标目录不存在"
            return
        fi
    fi
    
    # 拉取备份镜像
    log_info "拉取1panel备份镜像 $SELECTED_BACKUP..."
    docker pull "$SELECTED_BACKUP"
    
    # 创建临时容器来恢复数据
    log_info "正在恢复1panel数据到 $RESTORE_DIR..."
    docker run --name panel-restore "$SELECTED_BACKUP" /backup/restore_panel.sh
    
    # 从恢复的容器中提取数据
    docker cp panel-restore:/restored/. "$RESTORE_DIR/"
    docker rm panel-restore
    
    log_info "1panel数据已恢复到 $RESTORE_DIR"
    log_info "您可能需要重启1panel服务或相关服务才能使配置生效"
}

# 主菜单
show_menu() {
    echo
    log_question "请选择操作:"
    echo "1) 备份所有Docker容器到仓库"
    echo "2) 从仓库恢复Docker容器"
    echo "3) 备份1panel面板网站配置"
    echo "4) 恢复1panel面板网站配置"
    echo "5) 退出"
    echo
    log_question "请输入选项 (1-5):"
    read MENU_CHOICE
    
    case $MENU_CHOICE in
        1)
            login_docker_hub
            backup_containers
            ;;
        2)
            login_docker_hub
            restore_containers
            ;;
        3)
            login_docker_hub
            backup_1panel
            ;;
        4)
            login_docker_hub
            restore_1panel
            ;;
        5)
            log_info "退出程序"
            exit 0
            ;;
        *)
            log_error "无效的选择，请重新输入"
            show_menu
            ;;
    esac
}

# 清理函数
cleanup() {
    log_info "清理备份目录..."
    rm -rf "$BACKUP_DIR"
    docker logout
    log_info "清理完成"
}

# 主程序开始

# 设置清理钩子
trap cleanup EXIT

# 显示脚本信息
echo "======================================================"
echo -e "${GREEN}Docker 容器与1panel备份恢复工具${NC}"
echo "======================================================"
echo "此脚本可以帮助您备份所有Docker容器到Docker Hub，"
echo "或者从Docker Hub恢复之前备份的容器。"
echo "还可以备份和恢复1panel面板的网站配置。"
echo

# 显示主菜单
show_menu

exit 0 
