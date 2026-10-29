# ICPH Rack Tracker · 40-Rack Resource Management

Version 1.1 · A responsive rack-tracking site based on the supplied screenshots. Its UI is in English; this README is in Chinese. Built using React + Vite + Supabase for deployment to Cloudflare Pages (or any static web host).

## 当前版本功能

- **40 个 Rack**（#001–#040）；状态卡：绿 Available（在 ICPH 可上货）、棕 Occupied（厂内装货完成）、蓝 Out with cargo（厂外带货）、浅绿 Empty off-site（已卸货但还在厂外）；卡片显示项目、位置、Block/Floor/Zone 和实时累计时间（每 15 秒重新计算）。
- 通过 **Project 下拉筛选 / 全文搜索**，统计该项目目前厂内 Occupied、已送出但尚未卸货、以及卸货后仍在厂外的空 Rack。
- 每个 Rack 详情：Project / Block / Floor / Zone / Notes / Photos（最多 8 张，每张 ≤4 MB），可更新资料。
- **Project 和 Trailer 预先录入**，后续下拉选择；初始 Project 含截图展示的样例，Trailer 不会擅自编造号码。**一个 Rack 同一轮只能关联一个 Project、一个 Trailer**，每个 Rack 独立生成一条 Delivery Record。**一个 Trailer 同一时间只能承载一个未卸货 Rack**，卸货完成后可分配下一 Rack。
- 按要求只记录 **Project / Block / Floor / Zone**，不设 Cargo Quantity。
- 生命周期：`Available → Occupied → Dispatched → Unloaded → Returned to ICPH / Available`。
  - Occupied：保存项目/货物资料，开始占用计时。
  - Dispatched：强制选择 Trailer，创建不可被后续装货覆盖的 Delivery Record，开始出厂计时。
  - Unloaded：记录卸货完成与现场位置。Rack 显示**绿色系 Empty off-site**（空 Rack），但**不会计算进厂内 Available，也禁止再次上货**。
  - Returned：**必须先确认卸货，且 Rack 物理返回 ICPH 后**，才能点击 **Confirm return to ICPH · Set Available**。系统同时更新 Location 为 Factory - ICPH，然后才开放下一轮装货。旧货物快照保留在 Delivery Record。
- 每一步默认以**点击时的当前时间**记录，也可解除勾选、手动输入实际发生时间。
- 每个 Rack 的 History 页面列出近 **30 天事件**；允许纠正时间，线上数据库会另外记录旧时间/新时间/修改原因/修改人员。
- Delivery Records 支持按日期、Project、Rack、Trailer 搜索及 CSV 导出。
- **共享线上模式**：Supabase Auth 账号、Viewer / Editor / Admin 权限、事务内状态切换、RLS、私有图片存储、实时变更订阅及 45 秒备用刷新。
- **本地 Demo 模式**：不需要账号或数据库，浏览器 localStorage 保存数据；注意这种模式 **不能实现多人同步，且不同浏览器看不到同一份数据**。

## 升级说明（重要：如果已经使用上一版网站 / 数据库）

1. 将这个 ZIP 中的最新代码覆盖到原 GitHub 项目（不要覆盖自己的 `.env.local`）。如果是 Cloudflare Pages + GitHub，提交更新后由 Cloudflare 自动部署新版本。
2. **如果上一版已经连接 Supabase 并运行过 `supabase/schema.sql`**：请进入现有项目的 Supabase SQL Editor，运行新增的 **`supabase/upgrade_v1_1.sql`**（不是重新运行整个 schema）。该升级脚本仅替换状态转换函数，**不会清空 Rack、Project、Trailer、History 或 Delivery 记录**。
3. 如果尚未创建 Supabase 数据库，直接执行最新 `supabase/schema.sql` 即可，不必执行升级文件。
4. 在本地可运行 `npm test` 验证基础流程；前端安装依赖后可以运行 `npm run build`。

**状态定义**：外出 Rack 在卸货后会显示 `Empty · Off-site`（浅绿色），但仅 `Available at ICPH` 才允许下一轮 `Mark Occupied`。外出时的计时从 Dispatch 起算，卸货后另显示 Empty for 时间。按 Project 筛选时，这些空 Rack 显示为“last delivery”，不被计算进厂内 Occupied。

## A. 先运行 Demo（无需 Supabase）

1. 安装 Node.js（建议 20 或更新版本）。
2. 打开 PowerShell/终端并进入项目文件夹：
   ```powershell
   cd ICPH-Rack-Tracker
   npm install
   npm run dev
   ```
3. 打开终端提示的网址（一般为 `http://localhost:5173`）。
4. 暂时 **不要设置** `.env.local`，默认进入本地 Demo。40 个 Rack 初始为 Available。
5. 在 **Projects & Trailers** 增加真实 Trailer 号码，再通过 Rack 详情测试装货、出厂、卸货、回厂流程。卸货后先确认 Rack 的实际回厂，才能重新装货。

## B. 多人实时使用：连接 Supabase

1. 登录 https://supabase.com ，新建一个 Project，妥善保管数据库密码。
2. 打开 **SQL Editor**，执行 `supabase/schema.sql`。这会建立 40 个 Rack、操作日志、送货记录、权限规则、私有照片存储。
3. 在 **Authentication → Providers → Email** 禁止公开注册；在 **Authentication → Users** 管理页面创建/邀请内部用户。
4. 在 SQL Editor 执行（**将邮箱换成实际账号**）：
   ```sql
   insert into public.staff_roles(user_id,role)
   select id,'admin' from auth.users where email='your.admin@company.com'
   on conflict (user_id) do update set role=excluded.role;
   ```
   对管工用 `'editor'`；只看不改的人员用 `'viewer'`。账号必须先在 Authentication 建立。
5. 在 Project Settings → API 获取 `Project URL` 和 **anon / publishable key**（不要使用 service_role/secret key）。在项目根目录复制 `.env.example` 为 `.env.local`：
   ```env
   VITE_SUPABASE_URL=https://your-project.supabase.co
   VITE_SUPABASE_ANON_KEY=your-public-anon-or-publishable-key
   ```
6. 重新运行 `npm run dev`。现在用户需要登录；所有内部用户查看同一份数据，Editor 可操作 Rack。
7. 在 **Database → Publications → supabase_realtime** 检查五张业务表（racks, rack_events, deliveries, projects, trailers）已启用。SQL 文件已尝试自动配置。

**安全：** 前端 `.env.local` 的 key 不是数据库管理员密码；数据库通过 Supabase Auth 和 Row Level Security 保护。绝对不要把 `service_role` 密钥上传到 GitHub。项目管理页面允许 Editor 追加 Project / Trailer，删除和禁用功能暂未开放以免破坏历史关联。

## C. 部署 Cloudflare Pages

**GitHub 连接方式（推荐）：**

1. 将整个 `ICPH-Rack-Tracker` 项目上传到 GitHub（不要上传 `.env.local`，下方 `.gitignore` 会排除）。
2. Cloudflare → Workers & Pages → Create → Pages → Connect to Git → 选择 Repository。
3. 配置：**Framework preset = Vite**, **Build command = `npm run build`**, **Build output directory = `dist`**, **Root directory = `/`**（若此项目放在子目录则写子目录路径）。
4. Cloudflare Pages → Settings → Variables and Secrets 添加 `VITE_SUPABASE_URL` 和 `VITE_SUPABASE_ANON_KEY` 两个 Production 环境变量，保存后重新部署。
5. 可以在 Pages 生成的域名打开网站，多设备登录共享数据。

**本地发布方式：** 运行 `npm run build`，然后将 `dist/` 中构建文件上传到静态网站服务。请勿直接上传源代码作为网页根目录。

## D. 30 天保留机制

- UI / API 仅显示近 30 天 `rack_events`；Delivery Record 在 Rack 回厂后至少再保留 30 天。
- 若希望后台自动删除历史数据，先在 Supabase 的 Database → Extensions 启用 `pg_cron`，再执行 `supabase/retention_optional.sql`。删除 30 天前的 Rack Events，以及**回厂时间超过 30 天**的已结束 Delivery Records。仍在外的 Rack 的未完结 Delivery Record **绝不提前删除**。
- 目前 **Rack Photos 不自动清理**，避免误删仍在使用的照片。需要自动删除附件时，可后续安排单独的 Storage cleanup job。
- 不建议把“30 天保留”当成不可追溯删除：如有合规、质量追踪或交货争议要求，应先确认公司档案政策。CSV 可以在删除前导出保存。

## E. 主要文件

| 文件 | 用途 |
|---|---|
| `src/App.jsx` | 页面 UI、卡片、筛选、单 Rack 操作、History、Delivery Records |
| `src/api.js` | 本地 Demo / Supabase 访问、照片存储、实时更新 |
| `src/data.js` | Rack 初始数据、时间计算、Demo 状态切换、CSV |
| `src/styles.css` | 与参考截图一致的绿/棕状态卡和响应式布局 |
| `supabase/schema.sql` | 正式数据库、鉴权、事务 RPC、审核日志和 Realtime |
| `supabase/retention_optional.sql` | 可选定时清理旧历史数据 |

## 目前刻意没有擅自假设的业务规则

- **Cargo Quantity / Product Type / Weight**：截图只含 Project/Block/Floor/Zone，没有说明每个 Rack 可放几件 LPS/PHS/PBU 或最大载重；如需库存数量及装载容量，可新增这些字段。
- **同一 Rack 多个 Project**：当前设计为 **每趟只归属一个 Project**。如果实际可以混装多个 Project，需额外的 `rack_cargo_items` 子表，而不是强行塞入一个 Project 名称。
- **Trailer 多 Rack**：系统允许多 Rack 选择同一 Trailer，但尚无 Trailer 一车多个 Rack 的 **Delivery Batch / DO No.**；可增加一次操作批量发车/打印 Delivery Order。
- **卸货 vs 回厂**：分为独立动作，避免“现场卸货后尚未回厂”时错误显示 Available。
- **库存/定位差异**：目前的 Rack 位置由人手操作更新，不是 GPS 追踪。

## 自测建议

1. 新增 Trailer `TEST-01`。
2. 在 #001 选择 Project，填写 Block/Floor/Zone，Mark Occupied：卡片转棕色。
3. 以 Project 筛选：厂内 Occupied 数应增加 1。
4. Dispatch Rack 选择 `TEST-01`：#001 改蓝色，并出现 Delivery Record。
5. Mark Unloaded：Rack 继续蓝色，出厂时间继续累计；Delivery Record 显示 Unloaded 时间。
6. Returned to ICPH → Mark Available：#001 变绿色，Project 关联从当前数据移除，但原送货记录仍有该 Project/Trailer/Block/Floor/Zone 快照。
7. 进入 #001 的 History，确认包含上述操作，尝试修改某条记录的时间。

**备注：** 由于生成文件的运行环境无法连接 npm registry，源码经过 JSX/JavaScript 语法检查与本地状态逻辑测试，但这里无法安装依赖执行真实浏览器端到端测试。部署前建议按上面的自测步骤验收。
