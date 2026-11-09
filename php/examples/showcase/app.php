<?php
/**
 * The showcase admin served from PHP that uses every capability of the SDK, as SHOWCASE.md describes it (the reference
 * is python/examples/showcase.py). This file declares the models and returns the configured Node; router.php serves
 * requests with it, heartbeat.php registers it, and ../showcase.php runs both in one command:
 *
 *   ERUPT_NODE_NAME=showcase ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 PORT=9090 php examples/showcase.php
 *
 * Storage is the SQLite file in ERUPT_DB (default showcase.db), so nothing in the spec is skipped for a memory
 * repository. Edit types without a property-type mapping keep the storage of their property (string / int /
 * float / array) and name the edit type in `type:`; form-only elements are `virtual`; MULTI_CHOICE holds a JSON
 * array (an `array` property), KEY_VALUE a JSON object (an `object` property).
 *
 * One deviation, from PHP's request model: under `php -S` / php-fpm every request starts from nothing, so the
 * "fetched rows" counter of afterFetch counts the rows of the current request only (it cannot persist in-process).
 */

namespace Erupt\Examples\Showcase;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\DataProxy;
use Erupt\Fail;
use Erupt\Model;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;
use Erupt\Query;
use Erupt\Repository;

require_once __DIR__ . '/../../autoload.php';

// ---------------------------------------------------------------- reference data

#[Erupt('Category', raw: ['tree' => ['pid' => 'parent'], 'dragSort' => ['field' => 'sort'],
    'drills' => [['title' => 'Articles', 'code' => 'Articles', 'link' => ['linkErupt' => 'Article', 'joinColumn' => 'category']]]])]
final class Category
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true, sortable: true)] public string $name;
    #[Field('Parent Id')] public ?int $parent;
    #[Field('Sort', sortable: true)] public ?int $sort;
}

#[Erupt('Author', raw: ['drills' => [['title' => 'Articles', 'code' => 'Articles',
    'link' => ['linkErupt' => 'Article', 'joinColumn' => 'author', 'linkCondition' => "status = 'published'"]]]])]
final class Author
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true)] public string $name;
    #[Field('Email', edit: ['inputType' => ['regex' => '^[^@\s]+@[^@\s]+\.[^@\s]+$']])] public ?string $email;
    #[Field('Active', search: true, notNull: true)] public bool $active;
}

#[Erupt('Tag')]
final class Tag
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true)] public string $name;
    #[Field('Color', type: 'COLOR')] public ?string $color;
}

/** The Publish operation's form; not registered. */
#[Erupt('Publish Options')]
final class PublishForm
{
    #[Field('Publish Date', type: 'DATE', notNull: true)] public string $publish_date;
}

#[Erupt('Audit Log', orderBy: 'id desc', power: ['add' => false, 'edit' => false, 'delete' => false])]
final class AuditLog
{
    #[Field(pk: true)] public int $id;
    #[Field('Action', search: true, choices: ['add' => 'Add', 'update' => 'Update', 'delete' => 'Delete'])] public ?string $action;
    #[Field('Article')] public ?string $article;
    #[Field('By', search: true)] public ?string $account;
    #[Field('At', sortable: true)] public ?\DateTimeImmutable $at;
}

// ---------------------------------------------------------------- the article's data proxy: every hook

final class ArticleProxy extends DataProxy
{
    /** The Audit Log repository, set where the node is built. */
    public static Repository $audit;
    /** Rows fetched so far: per request under `php -S` / php-fpm, which keep nothing between requests. */
    public static int $fetched = 0;

    public function searchCondition(array &$condition): void
    {
        $condition['status'] = 'published';
    }

    public function beforeFetch(array $conditions): string|array|null
    {
        return "status <> 'archived'";
    }

    public function afterFetch(array &$rows): void
    {
        self::$fetched += count($rows);
        if (getenv('ERUPT_DEBUG')) {
            error_log('rows fetched so far: ' . self::$fetched);
        }
    }

    public function addBehavior(array &$record): void
    {
        $record = array_merge($record, ['status' => 'draft', 'views' => 0, 'progress' => 0]);
    }

    public function validate(array &$record): void
    {
        if (($record['title'] ?? null) === 'forbidden') {
            throw new Fail('This title is not allowed');
        }
    }

    public function beforeAdd(array &$record): void
    {
        self::stampReview($record);
    }

    public function beforeUpdate(array &$record): void
    {
        self::stampReview($record);
    }

    public function afterAdd(array &$record): void
    {
        self::log('add', $record);
    }

    public function afterUpdate(array &$record): void
    {
        self::log('update', $record);
    }

    public function beforeDelete(array &$record): void
    {
        if (($record['status'] ?? null) === 'published') {
            throw new Fail('Unpublish it first');
        }
    }

    public function afterDelete(array &$record): void
    {
        self::log('delete', $record);
    }

    private static function stampReview(array &$record): void
    {
        if (($record['status'] ?? null) === 'review' && empty($record['review_at'])) {
            $record['review_at'] = new \DateTimeImmutable('now');
        }
    }

    private static function log(string $action, array $record): void
    {
        self::$audit->add(['action' => $action, 'article' => $record['title'] ?? null,
            'account' => Node::currentUser()['account'] ?? null, 'at' => new \DateTimeImmutable('now')]);
    }
}

// ---------------------------------------------------------------- the article: every field type and behaviour

#[Erupt('Article', orderBy: 'id desc', power: ['importable' => true], dataProxy: ArticleProxy::class, raw: [
    'linkTree' => ['field' => 'category'],
    'vis' => [
        ['title' => 'Drafts', 'code' => 'Drafts', 'type' => 'TABLE', 'filter' => "status = 'draft'", 'orderBy' => 'views desc'],
        ['title' => 'Board', 'code' => 'Board', 'type' => 'BOARD', 'boardView' => ['groupField' => 'status', 'sumField' => 'views']],
        ['title' => 'Calendar', 'code' => 'Calendar', 'type' => 'CALENDAR', 'calendarView' => ['dateField' => 'publish_date']],
        ['title' => 'Cards', 'code' => 'Cards', 'type' => 'CARD', 'cardView' => ['coverField' => 'cover']],
        ['title' => 'Timeline', 'code' => 'Timeline', 'type' => 'TIMELINE', 'timelineView' => ['dateField' => 'review_at']],
    ],
])]
final class Article
{
    private const CITIES = ['Paris', 'Tokyo', 'Lisbon', 'Austin'];

    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true, edit: ['inputType' => ['length' => 60]], onchange: 'summaryFromTitle')]
    public string $title;
    #[Field('Summary', type: 'TEXTAREA', table: false, edit: ['textareaType' => ['length' => 200]])] public ?string $summary;
    #[Field('Author', search: true)] public ?Author $author;
    #[Field('Category', search: true)] public ?Category $category;
    #[Field('Sub Category', table: false, edit: ['referenceTableType' => ['dependField' => 'category', 'dependColumn' => 'parent']])]
    public ?Category $sub_category;
    #[Field('Topic', tree: 'parent', table: false)] public ?Category $topic;
    #[Field('Tags (checkbox)', type: 'CHECKBOX', ref: Tag::class, table: false)] public array $tag_ids;
    #[Field('Reviewers', type: 'TRANSFER', ref: Author::class, table: false)] public array $reviewers;
    #[Field('Sections', type: 'TAB_TREE', ref: Category::class, table: false)] public array $sections;
    #[Field('Status', search: true, choices: ['draft' => 'Draft', 'review' => 'In Review', 'published' => 'Published', 'archived' => 'Archived'])]
    public ?string $status;
    #[Field('Level', fetch: 'levels')] public ?string $level;
    #[Field('Labels', type: 'TAGS', fetch: 'labels', edit: ['tagsType' => ['allowExtension' => true, 'joinSeparator' => ',']])]
    public ?string $labels;
    #[Field('City', type: 'AUTO_COMPLETE', complete: 'cities', edit: ['autoCompleteType' => ['triggerLength' => 1]])] public ?string $city;
    #[Field('Cover', type: 'ATTACHMENT', edit: ['attachmentType' => ['type' => 'IMAGE', 'maxLimit' => 1]])] public ?string $cover;
    #[Field('Views', sortable: true, edit: ['numberType' => ['min' => 0]])] public ?int $views;
    #[Field('Price', edit: ['numberType' => ['min' => 0, 'precision' => 2, 'prefix' => '$']])] public ?float $price;
    #[Field('Rating', type: 'RATE', sortable: true, edit: ['rateType' => ['count' => 5, 'allowHalf' => true]])] public ?float $rating;
    #[Field('Progress', type: 'SLIDER', edit: ['sliderType' => ['min' => 0, 'max' => 100, 'step' => 5]])] public ?int $progress;
    #[Field('Featured', search: true)] public ?bool $featured;
    #[Field('Theme Color', type: 'COLOR')] public ?string $color;
    #[Field('Icon', type: 'ICON', table: false)] public ?string $icon;
    #[Field('Publish Date', type: 'DATE', search: true, edit: ['search' => ['operator' => 'RANGE']])] public ?string $publish_date;
    #[Field('Review At', sortable: true)] public ?\DateTimeImmutable $review_at;
    #[Field('Content', type: 'HTML_EDITOR', table: false)] public ?string $content;
    #[Field('Notes', type: 'MARKDOWN', table: false)] public ?string $notes;
    #[Field('Meta (JSON)', type: 'CODE_EDITOR', table: false, edit: ['codeEditType' => ['language' => 'json']])] public ?string $meta;
    #[Field('Preview', type: 'BUTTON', click: 'preview')] public ?string $preview;

    // ------------------------------------------------ the node's own code (invoke)

    /** title onchange: suggest a summary while there is none. */
    public static function summaryFromTitle(array $form): array
    {
        return ($form['title'] ?? '') !== '' && empty($form['summary']) ? ['formData' => ['summary' => 'About ' . $form['title']]] : [];
    }

    /** level options: an expert level once the article is read a lot. */
    public static function levels(array $form): array
    {
        $options = ['beginner' => 'Beginner', 'advanced' => 'Advanced'];
        if ((float) ($form['views'] ?? 0) >= 1000) {
            $options['expert'] = 'Expert';
        }
        return $options;
    }

    public static function labels(array $form): array
    {
        return ['hot', 'new', 'classic'];
    }

    public static function cities(array $form, string $typed): array
    {
        return array_values(array_filter(self::CITIES, fn($c) => stripos($c, $typed) !== false));
    }

    public static function preview(array $form): array
    {
        $title = json_encode('Preview: ' . (string) ($form['title'] ?? ''), JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_APOS);
        return ['eval' => "alert($title)"];
    }

    // ------------------------------------------------ row operations

    #[Operation('Publish', icon: 'fa fa-paper-plane', form: PublishForm::class, ifExpr: "item.status !== 'published'")]
    public static function publish(OperationContext $op): void
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['status' => 'published', 'publish_date' => $op->param['publish_date']]);
        }
    }

    #[Operation('Feature', mode: 'SINGLE', icon: 'fa fa-star', confirm: 'Feature this article on the home page?')]
    public static function feature(OperationContext $op): void
    {
        $op->repo->update($op->rows[0]['id'], ['featured' => true]);
    }

    #[Operation('Archive', mode: 'MULTI_ONLY', icon: 'fa fa-archive', confirm: false)]
    public static function archive(OperationContext $op): void
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['status' => 'archived']);
        }
    }

    #[Operation('Stats', mode: 'BUTTON', icon: 'fa fa-bar-chart', show: 'isAdmin')]
    public static function stats(OperationContext $op): string
    {
        $total = $op->repo->page(new Query(limit: 1))[0];
        return "alert('$total articles')";
    }

    public static function isAdmin(?array $user): bool
    {
        return ($user['account'] ?? null) === 'admin';
    }
}

// ---------------------------------------------------------------- layout and JSON-valued components

#[Erupt('Component')]
final class Component
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true)] public string $name;
    #[Field('Guide', virtual: true, edit: ['type' => 'CALLOUT', 'calloutType' => ['value' => 'Layout and JSON-valued components.', 'style' => 'INFO']])]
    public ?string $intro;
    #[Field('Basic', virtual: true, edit: ['type' => 'DIVIDE'])] public ?string $basic;
    #[Field('Code', type: 'HIDDEN', table: false)] public ?string $code;
    #[Field('Roles', search: true, choices: ['ADMIN' => 'Admin', 'USER' => 'User', 'GUEST' => 'Guest'],
        edit: ['type' => 'MULTI_CHOICE', 'multiChoiceType' => ['type' => 'CHECKBOX']])]
    public array $roles;
    #[Field('Languages', choices: ['JAVA' => 'Java', 'PYTHON' => 'Python', 'GO' => 'Go', 'RUST' => 'Rust'],
        edit: ['type' => 'MULTI_CHOICE', 'multiChoiceType' => ['type' => 'SELECT']])]
    public array $langs;
    #[Field('Attributes', edit: ['type' => 'KEY_VALUE', 'keyValueType' => ['keyPlaceholder' => 'Key', 'valuePlaceholder' => 'Value']])]
    public object $attrs;
    #[Field('', virtual: true, edit: ['type' => 'EMPTY'])] public ?string $spacer;
    #[Field('Extra', virtual: true, edit: ['type' => 'DIVIDE'])] public ?string $extra;
    #[Field('Location', type: 'MAP')] public ?string $location;
    #[Field('Signature', type: 'SIGNATURE', table: false)] public ?string $signature;
    #[Field('Place & Sign', virtual: true, edit: ['type' => 'GROUP', 'groupType' => ['fields' => ['location', 'signature']]])]
    public ?string $place;
}

// ---------------------------------------------------------------- buttons, form behaviour, table display, server calls

/** The Rename operation's form; not registered. */
#[Erupt('Rename')]
final class RenameForm
{
    #[Field('New Name', notNull: true)] public string $name;
}

#[Erupt('Buttons & Forms', power: ['export' => false], raw: ['layout' => ['pageSize' => 20, 'tableLeftFixed' => 1]])]
final class Playground
{
    /** The node, set where it is built: Node Info calls the server back through it. */
    public static Node $node;

    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true, edit: ['search' => ['operator' => 'LIKE', 'lockOperator' => true],
        'inputType' => ['prefix' => [['value' => '@', 'label' => '@']], 'suffix' => [['value' => '.dev', 'label' => '.dev'], ['value' => '.io', 'label' => '.io']]],
        'placeHolder' => 'a short name', 'desc' => 'Shown first in the table'])]
    public string $name;
    #[Field('Kind', search: true, choices: ['simple' => 'Simple', 'advanced' => 'Advanced'])] public ?string $kind;
    #[Field('Level', fetch: 'levelsByKind', edit: ['choiceType' => ['dependField' => 'kind']])] public ?string $level;
    #[Field('Advanced Note', type: 'TEXTAREA', table: false, edit: ['dynamic' => [
        'dependField' => 'kind', 'condition' => "value === 'advanced'", 'match' => 'SHOW', 'noMatch' => 'HIDE']])]
    public ?string $note;
    #[Field('Code', edit: ['readOnly' => ['add' => false, 'edit' => true]])] public ?string $code;
    #[Field('Amount', edit: ['numberType' => ['prefix' => '$']], view: ['statistic' => 'SUM', 'className' => 'text-right', 'width' => '120px'])]
    public ?float $amount;
    #[Field('Score', view: ['statistic' => 'AVG'])] public ?float $score;
    #[Field('Skills', fetch: 'skills')] public array $skills;
    #[Field('Files', type: 'ATTACHMENT', table: false, edit: ['attachmentType' => ['type' => 'BASE', 'maxLimit' => 3, 'fileTypes' => ['pdf', 'txt', 'md']]])]
    public ?string $files;
    #[Field('Fill Sample', type: 'BUTTON', click: 'fill', edit: ['buttonType' => ['style' => 'primary', 'icon' => 'fa fa-magic']])] public ?string $fill;
    #[Field('Clear', type: 'BUTTON', click: 'clear', edit: ['buttonType' => ['danger' => true, 'confirm' => 'Clear the form?']])] public ?string $reset;
    #[Field('Who Am I', type: 'BUTTON', click: 'whoami', edit: ['buttonType' => ['fullSpan' => true, 'icon' => 'fa fa-user']])] public ?string $whoami;

    /** level options follow the kind (choiceType.dependField). */
    public static function levelsByKind(array $form): array
    {
        return ($form['kind'] ?? null) === 'advanced' ? ['high' => 'High', 'expert' => 'Expert'] : ['low' => 'Low', 'mid' => 'Mid'];
    }

    public static function skills(array $form): array
    {
        return ['java' => 'Java', 'python' => 'Python', 'go' => 'Go'];
    }

    public static function fill(array $form): array
    {
        return ['formData' => ['name' => 'sample', 'kind' => 'advanced', 'amount' => 42, 'score' => 4]];
    }

    public static function clear(array $form): array
    {
        return ['formData' => ['name' => '', 'amount' => 0, 'score' => 0]];
    }

    public static function whoami(array $form): array
    {
        return ['eval' => 'alert(' . self::js((string) (Node::currentUser()['account'] ?? '')) . ')'];
    }

    #[Operation('Rename', mode: 'SINGLE', form: RenameForm::class, tip: 'Give the row a new name')]
    public static function rename(OperationContext $op): void
    {
        $op->repo->update($op->rows[0]['id'], ['name' => $op->param['name']]);
    }

    #[Operation('Double', ifExpr: 'item.amount > 0', raw: ['ifExprBehavior' => 'HIDE'])]
    public static function double(OperationContext $op): void
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['amount' => ($row['amount'] ?? 0) * 2]);
        }
    }

    #[Operation('Reset Amounts', confirm: 'Reset the amounts?', raw: ['fold' => true])]
    public static function reset_amounts(OperationContext $op): void
    {
        foreach ($op->rows as $row) {
            $op->repo->update($row['id'], ['amount' => 0]);
        }
    }

    #[Operation('Node Info', mode: 'BUTTON', icon: 'fa fa-info-circle')]
    public static function node_info(OperationContext $op): string
    {
        $account = (string) ($op->user['account'] ?? '');
        try {
            $roles = count((array) (self::$node->userInfo()['roles'] ?? []));
        } catch (\Throwable) {
            $roles = 0;
        }
        try {
            $config = strlen(self::$node->config());
        } catch (\Throwable) {
            $config = 0;
        }
        return 'alert(' . self::js("$account: $roles roles, config $config chars") . ')';
    }

    /** A JavaScript string literal of $text, safe inside a script. */
    private static function js(string $text): string
    {
        return json_encode($text, JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_APOS);
    }
}

// ---------------------------------------------------------------- seed data

const SEEDS = [
    Category::class => [
        ['name' => 'Tech', 'parent' => null, 'sort' => 1], ['name' => 'Python', 'parent' => 1, 'sort' => 2],
        ['name' => 'Go', 'parent' => 1, 'sort' => 3], ['name' => 'Life', 'parent' => null, 'sort' => 4],
        ['name' => 'Travel', 'parent' => 4, 'sort' => 5],
    ],
    Author::class => [
        ['name' => 'Ann', 'email' => 'ann@example.com', 'active' => true],
        ['name' => 'Bob', 'email' => 'bob@example.com', 'active' => true],
        ['name' => 'Cy', 'email' => 'cy@example.com', 'active' => false],
    ],
    Tag::class => [['name' => 'intro', 'color' => '#1677ff'], ['name' => 'guide', 'color' => '#52c41a'], ['name' => 'news', 'color' => '#fa8c16']],
    Article::class => [
        ['title' => 'Hello Erupt', 'summary' => 'A first look at erupt nodes', 'author' => 1, 'category' => 2, 'topic' => 2,
            'tag_ids' => [1, 2], 'reviewers' => [2], 'sections' => [1, 2], 'status' => 'published', 'level' => 'beginner',
            'labels' => 'hot,new', 'city' => 'Paris', 'views' => 120, 'price' => 9.9, 'rating' => 4.5, 'progress' => 100, 'featured' => true,
            'color' => '#1677ff', 'icon' => 'fa fa-book', 'publish_date' => '2026-10-01', 'review_at' => '2026-10-02T10:00:00.000',
            'content' => '<p>Hello</p>', 'notes' => '# Hello', 'meta' => '{"a":1}'],
        ['title' => 'Go Tips', 'author' => 2, 'category' => 3, 'topic' => 3, 'tag_ids' => [2], 'status' => 'review', 'level' => 'advanced',
            'labels' => 'classic', 'views' => 30, 'price' => 0, 'rating' => 3, 'progress' => 60, 'featured' => false],
        ['title' => 'Weekend Trip', 'author' => 3, 'category' => 5, 'topic' => 5, 'status' => 'draft', 'views' => 0, 'rating' => 0,
            'progress' => 10, 'featured' => false],
    ],
    Component::class => [
        ['name' => 'Sample A', 'code' => 'C-001', 'roles' => ['ADMIN', 'USER'], 'langs' => ['JAVA', 'GO'], 'attrs' => ['env' => 'prod', 'tier' => '1']],
        ['name' => 'Sample B', 'code' => 'C-002', 'roles' => ['GUEST'], 'langs' => ['PYTHON'], 'attrs' => []],
    ],
    Playground::class => [
        ['name' => 'alpha', 'kind' => 'simple', 'level' => 'low', 'code' => 'A-1', 'amount' => 10, 'score' => 3, 'skills' => ['java']],
        ['name' => 'beta', 'kind' => 'advanced', 'level' => 'expert', 'note' => 'deep dive', 'code' => 'B-1', 'amount' => 0, 'score' => 5,
            'skills' => ['python', 'go']],
        ['name' => 'gamma', 'kind' => 'simple', 'level' => 'mid', 'code' => 'G-1', 'amount' => 25, 'score' => 4, 'skills' => []],
    ],
];

/** One repository per registered model, on the SQLite file in ERUPT_DB (registering creates the tables). */
function repositories(): array
{
    static $repos = null;
    if ($repos === null) {
        $pdo = new \PDO('sqlite:' . (getenv('ERUPT_DB') ?: 'showcase.db'));
        $repos = [];
        foreach ([Category::class => 'category', Author::class => 'author', Tag::class => 'tag', Article::class => 'article',
                     Component::class => 'component', AuditLog::class => 'audit_log', Playground::class => 'playground'] as $class => $table) {
            $repos[$class] = new PdoRepository($pdo, $table);
        }
    }
    return $repos;
}

/** Sample records, each model only while its table is empty; the launcher runs it once before serving. */
function seed(): void
{
    $repos = repositories();
    foreach (SEEDS as $class => $records) {
        if ($repos[$class]->page(new Query(limit: 1))[0] === 0) {
            array_walk($records, fn($record) => $repos[$class]->add(record($class, $record)));
        }
    }
}

/** A seed row as the repository stores it: the same coercion the node applies to a record from the server. */
function record(string $class, array $row): array
{
    $model = Model::of($class);
    return array_combine(array_keys($row), array_map(fn($k, $v) => $model->fields[$k]->coerce($v), array_keys($row), $row));
}

ArticleProxy::$audit = repositories()[AuditLog::class];
$node = new Node(getenv('ERUPT_NODE_NAME') ?: 'showcase', (string) getenv('ERUPT_ACCESS_TOKEN'), getenv('ERUPT_SERVER') ?: 'http://localhost:8080');
Playground::$node = $node;
foreach (repositories() as $class => $repo) {
    $node->register($class, $repo);
}
return $node;
