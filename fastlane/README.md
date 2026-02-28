# Echo Fastlane 部署指南

## 快速开始

### 1. 安装依赖
```bash
cd ~/Echo
fastlane install
```

### 2. 构建并上传 TestFlight
```bash
fastlane beta
```

### 3. 本地 Simulator 测试构建
```bash
fastlane sim
```

## 自动化流程

### 手动触发
```bash
cd ~/Echo
fastlane beta
```

### CI/CD 自动触发
在 GitHub Actions 或 Xcode Cloud 中配置：
```yaml
- name: Deploy to TestFlight
  run: fastlane beta
```

## TestFlight 测试

1. 收到邀请后，在 iPhone 上打开 TestFlight
2. 安装 Echo 测试版
3. 测试并反馈

## 常见问题

Q: 上传失败怎么办？
A: 检查 Apple Developer 账号是否过期，证书是否有效

Q: 如何查看构建状态？
A: 访问 App Store Connect - TestFlight
