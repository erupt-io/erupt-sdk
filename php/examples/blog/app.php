<?php
/**
 * A blog admin served from PHP: the models and the configured Node, shared by router.php (requests) and
 * heartbeat.php (registration). Create node 'blog' on the erupt server first.
 */

namespace Erupt\Examples\Blog;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;

require_once __DIR__ . '/../../autoload.php';

#[Erupt('Category')]
final class Category
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true, notNull: true)] public string $name;
    #[Field('Parent Id')] public ?int $parent;
}

#[Erupt('Publish Options')]
final class PublishForm
{
    #[Field('Publish Date', type: 'DATE', notNull: true)] public string $publish_date;
}

#[Erupt('Article', orderBy: 'id desc')]
final class Article
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true)] public string $title;
    #[Field('Category', search: true)] public ?Category $category;
    #[Field('Topic', tree: 'parent', table: false)] public ?Category $topic;
    #[Field('Status', choices: ['draft' => 'Draft', 'published' => 'Published'], search: true)] public string $status;
    #[Field('Views', sortable: true)] public int $views;
    #[Field('Featured', search: true)] public bool $featured;
    #[Field('Publish Date', type: 'DATE', search: true)] public string $publish_date;
    #[Field('Review At', sortable: true)] public \DateTimeImmutable $review_at;
    #[Field('Body', type: 'TEXTAREA', table: false)] public string $body;

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

$pdo = new \PDO('sqlite:' . (getenv('ERUPT_DB') ?: __DIR__ . '/blog.db'));
return (new Node('blog', (string) getenv('ERUPT_ACCESS_TOKEN'), getenv('ERUPT_SERVER') ?: 'http://localhost:8080'))
    ->register(Category::class, new PdoRepository($pdo, 'category'))
    ->register(Article::class, new PdoRepository($pdo, 'article'));
