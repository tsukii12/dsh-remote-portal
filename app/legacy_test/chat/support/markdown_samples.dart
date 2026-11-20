// Markdown a model really writes, one sample per construct, shared by the
// rendering tests and the goldens.

/// A real LaTeX reply (inline maths, a currency sentence that
/// must stay prose, and a multi-line display block).
const mathReply = r'''
质能方程 $E = mc^2$ 写在一行里，分式 $\frac{a+b}{c}$ 也是。

- 求和：$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$
- 高斯积分：$\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}$
- 希腊字母：$\alpha\beta\gamma \to \infty$

二阶矩阵的逆：

$$
\begin{pmatrix} a & b \\ c & d \end{pmatrix}^{-1} = \frac{1}{ad-bc}\begin{pmatrix} d & -b \\ -c & a \end{pmatrix}
$$

括号写法同样可以：\(x^2 + y^2 = r^2\)，以及

\[
\oint_C \mathbf{F}\cdot d\mathbf{r} = \iint_S (\nabla \times \mathbf{F}) \cdot d\mathbf{S}
\]

午饭 $5 and $10 两档，都不是公式；代码里的 `$HOME` 也不是。''';

/// Headings, paragraphs and mixed CJK / Latin text.
const headingsReply = '''
# 一级标题 Heading 1
正文段落：DeepSeek Harness（DSH）把模型、工具和工作区放在一起，**粗体**、*斜体*、~~删除线~~、`inline code` 混排时行高不跳。

## 二级标题
中文与 English 混排，全角标点「引号」、（括号）、——破折号……都不应被挤压。

### 三级标题
#### 四级标题
##### 五级标题
###### 六级标题
最后一段。''';

/// Lists: nested, ordered, task lists.
const listsReply = '''
1. 第一步：安装依赖
2. 第二步：运行测试
   - 单元测试
   - 组件测试
     1. 浅色
     2. 深色
3. 第三步：提交

- 无序一项，文字比较长需要换行的时候，第二行应该和第一行的文字对齐，而不是和圆点对齐
- [ ] 待办：整理数据
- [x] 已完成：修复上线

9. 第九步
10. 第十步：两位数的编号完整显示
11. 第十一步''';

/// Blockquotes and GitHub alerts.
const quotesReply = '''
> 引用一段话。
>
> > 嵌套的引用。

> [!NOTE]
> 这是一条说明。

> [!TIP]
> 用 `flutter test --update-goldens` 重新生成截图。

> [!IMPORTANT]
> 发布前先跑完整测试。

> [!WARNING]
> 这个操作会覆盖本地改动。

> [!CAUTION]
> 删除后无法恢复。''';

/// A table with alignment and inline Markdown in cells.
const tableReply = '''
| 模型 | 上下文 | 价格（元 / 百万 tokens） | 说明 |
|:---|:---:|---:|---|
| DeepSeek-V4-Pro | 128K | 4.00 | **默认**，推理更强 |
| DeepSeek-V41-Flash | 64K | 1.00 | 更快、`更省` |
| 自定义 | — | — | 见[文档](https://example.com) |''';

/// Code: a fenced block, a diff, and a Mermaid chart.
const codeReply = '''
```dart
void main() {
  final greeting = 'Hello, DSH!'; // 一行很长的注释，用来检查横向滚动是否正常而不会把整个页面撑宽
  print(greeting);
}
```

```diff
@@ -1,3 +1,3 @@
 import 'a.dart';
-final retries = 3;
+final retries = 1;
```

```mermaid
graph TD
  A[用户] --> B{DSH}
  B --> C[模型]
```''';

/// Rules, footnotes, HTML bits, "Key: value" lines, long words.
const miscReply = '''
状态: 运行中
版本: 0.2.1

---

脚注引用[^1]，上标 x<sup>2</sup>，下标 H<sub>2</sub>O，快捷键 <kbd>Ctrl</kbd>+<kbd>C</kbd>，<u>下划线</u>，<mark>高亮</mark>。<br>换行之后。

<details>
<summary>展开细节</summary>

折叠起来的内容。

</details>

超长链接 https://example.com/a/very/long/path/that/keeps/going/and/going/without/any/spaces/at/all?query=1 以及超长单词 Pneumonoultramicroscopicsilicovolcanoconiosis 都要换行。表情 🎉👍

[^1]: 这是脚注内容。''';
