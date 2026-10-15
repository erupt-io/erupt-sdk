<?php
/**
 * A blog admin served from PHP (the shared showcase model, SHOWCASE.md): the models and the configured Node,
 * shared by router.php (requests) and heartbeat.php (registration). Create node 'blog' on the erupt server first.
 */

namespace Erupt\Examples\Blog;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Model;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;
use Erupt\Query;

require_once __DIR__ . '/../../autoload.php';

#[Erupt('Category')]
final class Category
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true, sortable: true)] public string $name;
    #[Field('Parent Id')] public ?int $parent;
    #[Field('Sort', sortable: true)] public ?int $sort;
}

#[Erupt('Publish Options')]
final class PublishForm
{
    #[Field('Publish Date', type: 'DATE', notNull: true)] public string $publish_date;
}

/**
 * The shared showcase model (SHOWCASE.md). Edit types without a property-type mapping keep the storage of
 * their property (string or number) and switch the widget through the raw `edit` attributes.
 */
#[Erupt('Article', orderBy: 'id desc', power: ['importable' => true])]
final class Article
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true, edit: ['inputType' => ['length' => 60]])] public string $title;
    #[Field('Summary', type: 'TEXTAREA', table: false, edit: ['textareaType' => ['length' => 200]])] public ?string $summary;
    #[Field('Category', search: true)] public ?Category $category;
    #[Field('Topic', tree: 'parent', table: false)] public ?Category $topic;
    #[Field('Status', choices: ['draft' => 'Draft', 'review' => 'In Review', 'published' => 'Published'], search: true)] public string $status;
    #[Field('Tags', edit: ['type' => 'TAGS', 'tagsType' => ['allowExtension' => true, 'joinSeparator' => ',', 'maxTagCount' => 0]])] public ?string $tags;
    #[Field('Views', sortable: true, edit: ['numberType' => ['min' => 0]])] public int $views;
    #[Field('Price', edit: ['numberType' => ['min' => 0, 'precision' => 2, 'prefix' => '$']])] public ?float $price;
    #[Field('Rating', edit: ['type' => 'RATE', 'rateType' => ['count' => 5, 'allowHalf' => true, 'character' => '']])] public ?float $rating;
    #[Field('Progress', edit: ['type' => 'SLIDER', 'sliderType' => ['min' => 0, 'max' => 100, 'step' => 5, 'dots' => false, 'markPoints' => []]])] public ?int $progress;
    #[Field('Featured', search: true)] public bool $featured;
    #[Field('Theme Color', edit: ['type' => 'COLOR', 'colorType' => ['alpha' => false, 'showText' => true, 'presets' => []]])] public ?string $color;
    #[Field('Icon', table: false, edit: ['type' => 'ICON'])] public ?string $icon;
    #[Field('Publish Date', type: 'DATE', search: true)] public ?string $publish_date;
    #[Field('Review At', sortable: true)] public ?\DateTimeImmutable $review_at;
    #[Field('Content', table: false, edit: ['type' => 'HTML_EDITOR', 'htmlEditorType' => ['value' => 'CKEDITOR']])] public ?string $content;
    #[Field('Notes', table: false, edit: ['type' => 'MARKDOWN'])] public ?string $notes;
    #[Field('Meta (JSON)', table: false, edit: ['type' => 'CODE_EDITOR', 'codeEditType' => ['language' => 'json', 'height' => 300, 'hints' => []]])] public ?string $meta;

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
}

/**
 * Every component a node can declare without extra endpoints: form-only elements are `virtual`, MULTI_CHOICE
 * holds a JSON array (an `array` property), KEY_VALUE a JSON object (an `object` property).
 */
#[Erupt('Component')]
final class Component
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true)] public string $name;
    #[Field('Guide', virtual: true, edit: ['type' => 'CALLOUT', 'calloutType' => [
        'value' => 'Every component a node can declare without extra endpoints.', 'style' => 'INFO']])]
    public ?string $intro;
    #[Field('Basic', virtual: true, edit: ['type' => 'DIVIDE'])] public ?string $basic;
    #[Field('Code', table: false, edit: ['type' => 'HIDDEN'])] public ?string $code;
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
    #[Field('Location', edit: ['type' => 'MAP'])] public ?string $location;
    #[Field('Signature', table: false, edit: ['type' => 'SIGNATURE'])] public ?string $signature;
    #[Field('Place & Sign', virtual: true, edit: ['type' => 'GROUP', 'groupType' => ['fields' => ['location', 'signature']]])]
    public ?string $place;
}

function pdo(): \PDO
{
    return new \PDO('sqlite:' . (getenv('ERUPT_DB') ?: __DIR__ . '/blog.db'));
}

/** Sample records for empty tables; heartbeat.php runs it once at start. */
function seed(): void
{
    $fill = function (string $class, string $table, array $records): void {
        $repo = new PdoRepository(pdo(), $table);
        $repo->bind(Model::of($class));
        if ($repo->page(new Query(limit: 1))[0] === 0) {
            array_walk($records, fn($record) => $repo->add($record));
        }
    };
    $fill(Category::class, 'category', [
        ['name' => 'Tech', 'parent' => null, 'sort' => 1],
        ['name' => 'Python', 'parent' => 1, 'sort' => 1],
        ['name' => 'Go', 'parent' => 1, 'sort' => 2],
        ['name' => 'Life', 'parent' => null, 'sort' => 2],
        ['name' => 'Travel', 'parent' => 4, 'sort' => 1],
    ]);
    $fill(Article::class, 'article', [
        ['title' => 'Hello Erupt', 'summary' => 'A first look at erupt nodes.', 'category' => 2, 'topic' => 2, 'status' => 'published',
            'tags' => 'intro,erupt', 'views' => 120, 'price' => 9.9, 'rating' => 4.5, 'progress' => 100, 'featured' => true,
            'color' => '#1677ff', 'icon' => 'fa fa-book', 'publish_date' => '2026-10-01', 'review_at' => '2026-10-02T10:00:00.000',
            'content' => '<p>Hello</p>', 'notes' => '# Hello', 'meta' => '{"a":1}'],
        ['title' => 'Go Tips', 'category' => 3, 'topic' => 3, 'status' => 'review', 'tags' => 'go', 'views' => 30, 'price' => 0,
            'rating' => 3, 'progress' => 60, 'featured' => false],
        ['title' => 'Weekend Trip', 'category' => 5, 'topic' => 5, 'status' => 'draft', 'views' => 0, 'rating' => 0, 'progress' => 10,
            'featured' => false],
    ]);
    $fill(Component::class, 'component', [
        ['name' => 'Sample A', 'code' => 'C-001', 'roles' => ['ADMIN', 'USER'], 'langs' => ['JAVA', 'GO'], 'attrs' => ['env' => 'prod', 'tier' => '1']],
        ['name' => 'Sample B', 'code' => 'C-002', 'roles' => ['GUEST'], 'langs' => ['PYTHON'], 'attrs' => new \stdClass()],
    ]);
}

$pdo = pdo();
return (new Node(getenv('ERUPT_NODE_NAME') ?: 'blog', (string) getenv('ERUPT_ACCESS_TOKEN'), getenv('ERUPT_SERVER') ?: 'http://localhost:8080'))
    ->register(Category::class, new PdoRepository($pdo, 'category'))
    ->register(Article::class, new PdoRepository($pdo, 'article'))
    ->register(Component::class, new PdoRepository($pdo, 'component'));
