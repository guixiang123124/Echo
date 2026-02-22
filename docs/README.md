# Echo Website

产品官网，部署在 Vercel。

## 本地预览

```bash
cd docs
python3 -m http.server 8080
# 访问 http://localhost:8080
```

## 部署到生产

```bash
bash ../scripts/deploy_docs_vercel.sh prod
```

## 页面结构

- `index.html` - 首页（自动跳转到落地页）
- `landing.html` - 产品营销落地页
- `privacy.html` - 隐私政策
- `support.html` - 支持页面

## 待办

- [ ] 添加英文版落地页
- [ ] 添加下载统计
- [ ] 添加 Windows/Android 候补表单
