const controlsData = <String, Object?>{
  'form': {
    'name': 'Ada',
    'notes': 'First line\nSecond line',
    'amount': 12.5,
    'count': 2,
    'enabled': true,
    'level': 40,
    'range': [20, 70],
    'category': 'b',
    'mode': 'a',
    'tags': ['one'],
    'date': '2026-10-27',
    'time': '09:30',
    'rating': 3,
  },
};

const inputFixture = <String, Object?>{
  'v': 2,
  'type': 'form',
  'label': 'Configuration',
  'submit': 'save',
  'submitLabel': 'Save settings',
  'children': [
    {
      'type': 'textField',
      'label': 'Name',
      'bind': 'data.form.name',
      'placeholder': 'Enter a name',
      'required': true,
      'maxLength': 80,
    },
    {'type': 'textField', 'label': 'Notes', 'bind': 'data.form.notes', 'multiline': true, 'maxLines': 3},
    {'type': 'number', 'label': 'Amount', 'bind': 'data.form.amount', 'min': 0, 'max': 100},
    {'type': 'stepper', 'label': 'Count', 'bind': 'data.form.count', 'min': 0, 'max': 10},
    {'type': 'toggle', 'label': 'Enable notifications', 'bind': 'data.form.enabled'},
    {'type': 'slider', 'label': 'Level', 'bind': 'data.form.level', 'min': 0, 'max': 100, 'step': 5},
    {'type': 'slider', 'label': 'Range', 'bind': 'data.form.range', 'range': true, 'min': 0, 'max': 100, 'step': 5},
    {
      'type': 'select',
      'label': 'Category',
      'bind': 'data.form.category',
      'options': [
        {'label': 'Alpha', 'value': 'a'},
        {'label': 'A longer second category', 'value': 'b'},
      ],
    },
    {
      'type': 'segmented',
      'label': 'Mode',
      'bind': 'data.form.mode',
      'options': [
        {'label': 'A', 'value': 'a'},
        {'label': 'A longer wrapped option', 'value': 'b'},
      ],
    },
    {
      'type': 'chips',
      'label': 'Tags',
      'bind': 'data.form.tags',
      'multi': true,
      'options': ['one', 'two', 'three'],
    },
    {'type': 'date', 'label': 'Date', 'bind': 'data.form.date'},
    {'type': 'time', 'label': 'Time', 'bind': 'data.form.time'},
    {'type': 'rating', 'label': 'Rating', 'bind': 'data.form.rating', 'max': 5},
    {
      'type': 'metric',
      'label': 'Total',
      'value': {'=': 'data.form.amount * data.form.count'},
    },
  ],
};

const structureFixture = <String, Object?>{
  'v': 2,
  'type': 'stack',
  'children': [
    {
      'type': 'tabs',
      'items': [
        {
          'label': 'Overview',
          'children': [
            {'type': 'text', 'text': 'First tab'},
          ],
        },
        {
          'label': 'Details',
          'children': [
            {'type': 'text', 'text': 'Second tab'},
          ],
        },
      ],
    },
    {
      'type': 'collapsible',
      'label': 'Folded content',
      'children': [
        {'type': 'text', 'text': 'Revealed content'},
      ],
    },
    {
      'type': 'accordion',
      'items': [
        {
          'label': 'Group A',
          'children': [
            {'type': 'text', 'text': 'Group A content'},
          ],
        },
        {
          'label': 'Group B',
          'children': [
            {'type': 'text', 'text': 'Group B content'},
          ],
        },
      ],
    },
    {
      'type': 'carousel',
      'items': [
        {
          'label': 'Page one',
          'children': [
            {'type': 'text', 'text': 'First page'},
          ],
        },
        {
          'label': 'Page two',
          'children': [
            {'type': 'text', 'text': 'Second page'},
          ],
        },
      ],
    },
    {
      'type': 'grid',
      'columns': 2,
      'children': [
        {
          'type': 'stack',
          'children': [
            {'type': 'badge', 'text': 'Ready'},
            {'type': 'text', 'text': 'Nested grid content'},
          ],
        },
        {'type': 'tag', 'text': 'Native'},
      ],
    },
    {
      'type': 'timeline',
      'items': [
        {
          'label': 'Draft',
          'children': [
            {'type': 'text', 'text': 'Created locally'},
          ],
        },
        {
          'label': 'Saved',
          'children': [
            {'type': 'text', 'text': 'Confirmed by the plugin'},
          ],
        },
      ],
    },
    {'type': 'codeBlock', 'language': 'javascript', 'code': 'const total = price * count;\nconsole.log(total);'},
    {'type': 'avatar', 'alt': 'Profile picture', 'src': 'asset:avatar.png', 'caption': 'Ignored for avatar geometry'},
    {'type': 'divider'},
    {'type': 'spacer', 'size': 'M'},
  ],
};
