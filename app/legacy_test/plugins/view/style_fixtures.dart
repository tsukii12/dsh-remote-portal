// Style-only v2 fixture: the same JSON retains meaningful v1 text fallbacks.
const styleGallery = <String, Object?>{
  'v': 2,
  'accent': 'teal',
  'type': 'stack',
  'style': {'gap': 'L'},
  'children': [
    {
      'type': 'text',
      'text': '专注于今天',
      'style': {'size': 'display', 'weight': 'bold'},
    },
    {
      'type': 'text',
      'text': 'Focus on today',
      'style': {'size': 'subtitle', 'color': 'teal'},
    },
    {
      'type': 'text',
      'text': '完成 7 / 10，继续保持。',
      'spans': [
        {'text': '完成 ', 'color': 'gray'},
        {'text': '7 / 10', 'weight': 'semibold', 'mono': true, 'background': 'green'},
        {'text': '，继续保持。', 'color': 'green'},
      ],
    },
    {
      'type': 'row',
      'style': {
        'columns': [1, 1],
        'gap': 'M',
      },
      'children': [
        {
          'type': 'stack',
          'style': {'card': 'tinted', 'padding': 'M', 'background': 'teal'},
          'children': [
            {
              'type': 'metric',
              'label': '本周专注',
              'value': '12.4 h',
              'caption': '比上周增加 2.1 h',
              'style': {'size': 'title', 'weight': 'semibold', 'color': 'teal'},
            },
          ],
        },
        {
          'type': 'stack',
          'style': {'card': 'outlined', 'padding': 'M'},
          'children': [
            {
              'type': 'metric',
              'label': '完成率',
              'value': '70%',
              'style': {'size': 'title', 'align': 'end'},
            },
          ],
        },
      ],
    },
    {
      'type': 'stack',
      'style': {'card': 'surface', 'padding': 'L', 'gap': 'S', 'dividers': true},
      'children': [
        {
          'type': 'text',
          'text': '下一个目标',
          'style': {'weight': 'medium'},
        },
        {
          'type': 'text',
          'text': '写下一个清晰的小目标，留出足够的时间完成它。',
          'style': {'size': 'body', 'maxLines': 2},
        },
        {
          'type': 'text',
          'text': '留白也是计划的一部分',
          'style': {'size': 'caption', 'italic': true, 'underline': true, 'align': 'center'},
        },
      ],
    },
    {
      'type': 'text',
      'text': '已完成的旧计划',
      'style': {'strike': true, 'color': 'gray'},
    },
    {
      'type': 'text',
      'text': 'focus.week = 12.4',
      'style': {'size': 'mono', 'color': 'indigo'},
    },
    {
      'type': 'actions',
      'items': [
        {'label': '复制摘要', 'icon': 'summary', 'action': 'copy'},
        {'label': '查看完整计划', 'action': 'details'},
      ],
    },
  ],
};
