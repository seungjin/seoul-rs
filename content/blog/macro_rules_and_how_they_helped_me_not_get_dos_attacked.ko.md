+++
draft = false
title = "macro_rules!를 이용해 DOS 공격을 막아보기"
date = "2026-04-18"
[taxonomies]
authors = ["Charles Johnson"]
tags = ["rust", "macros", "GraphQL"]
+++

# 소개

안녕하세요, 저는 Charles라고 합니다. 오늘은 Rust로 작성된 GraphQL 서버에서 겪었던 몇 가지 문제와, `macro_rules!` 매크로를 작성하여 해당 문제의 해결책에 필요한 상용구 코드(boilerplate)를 어떻게 줄였는지 공유하고자 합니다.
    

# 문제점

## GraphQL 스키마의 순환 타입 참조

    GraphQL의 단점 중 하나는 순환 타입 참조(cyclic type references)를 허용한다는 점입니다. 이는 임의의 중첩된 쿼리를 처리하게 만들어, 단일 요청에 과도한 리소스를 소모하게 할 수 있습니다. 이전 회사에서 GraphQL 서버를 초기부터 구축할 때는 이를 피했었지만, [Clear](https://getclearapp.com)에 합류한 후 스키마에 여러 순환 타입 참조가 있는 것을 발견했습니다.

[GraphQL 스키마](https://graphql.org/learn/schema/#type-language)에서의 순환 타입 참조 예시:

```graphql
type Query {
    foo: Foo
}

type Foo {
    bar: Bar
    result: Int
}

type Bar {
   foo: Foo
   result: Int
}
```

이 경우, 다음과 같이 임의로 중첩된 [GraphQL 쿼리](https://spec.graphql.org/draft/#root-operation-type)가 가능해집니다.

#### 중첩 쿼리
```graphql
query {
    foo {
        bar {
            foo {
                bar {
                    result
                }
                result
            }
            result
        }
        result
    }
    result
}
```
`foo { bar { foo { bar {...`로 이어지는 체인은 무한히 길어질 수 있으며, 표준 GraphQL 서버는 쿼리 전체를 처리하려고 시도할 것입니다.

## 결과 및 영향

결국 거대화된 쿼리는 GraphQL 서버를 압도하여 다른 요청을 느리게 만들고, 심지어 서버나 다른 다운스트림 서비스를 중단시킬 수도 있습니다. 이러한 쿼리는 순환 내의 필드 중 하나가 [List](https://graphql.org/learn/schema/#list) 타입일 경우 그리 깊지 않아도 문제가 됩니다. 여러 아이템을 반환하는 리스트가 존재하면 응답 크기가 쿼리 깊이에 따라 기하급수적으로 증가하여, 비대칭적인 공격 벡터를 제공하게 됩니다.

또한, 순환 내의 필드에 대해 [DataLoader 패턴](https://github.com/graphql-rust/juniper/blob/master/book/src/advanced/dataloader.md) 등을 구현하여 [N+1 문제](https://graphql.org/learn/performance/#the-n1-problem)를 해결하지 못하면, 과도한 수의 데이터베이스 쿼리가 발생할 수 있습니다. 이는 가용한 데이터베이스 연결을 빠르게 소모하여 요청 타임아웃을 유발하거나, 메모리 부족으로 데이터베이스 서버를 중단시킬 수도 있습니다.

따라서 이러한 순환 타입 참조를 포함한 GraphQL 서버를 프로덕션에 배포하고 클라이언트가 이를 의존하게 만드는 것은 피해야 할 이유가 많습니다. 하지만 이미 상황은 벌어졌고, 저는 이러한 순환 타입 참조가 악용되는 것을 방지할 방법을 찾아야 했습니다.

# 해결책

Clear 앱이 순환 유형 참조(cyclic type references)에 의존하여 생성할 수 있는 쿼리들이 무엇인지에 따라, 기존 클라이언트들에 영향을 주지 않으면서도 서버를 업데이트하려고 합니다.

## 단순 중첩 쿼리

예를 들어, 클라이언트가 단일 쿼리에 대해서만 순환 타입 참조를 사용하고 있다면:
```graphql
query {
    foo {
        bar {
            foo {
                result
            }
        }
    }
}
```
`Bar`의 정의를 다음과 같이 변경할 수 있습니다.
```graphql
type Bar {
    foo: FooWithJustResult
    result: Int
}

type FooWithJustResult {
    result: Int
}
```

이렇게 하면 클라이언트를 깨뜨리지 않고 순환 타입 참조를 끊을 수 있습니다.

하지만 Clear는 쿼리를 [프래그먼트(fragments)](https://spec.graphql.org/draft/#sec-Language.Fragments)로 구성하고 있으며, 이는 불행히도 클라이언트를 특정 GraphQL 타입에 결합시킵니다. 설령 다른 타입이 동일한 인라인 쿼리에 대해 호환되더라도 말이죠.

## 프래그먼트가 포함된 쿼리

예를 들어, 클라이언트가 위에서 본 인라인 쿼리를 아래와 같이 구성했다고 합시다:

```graphql
query {
    foo {
        bar {
            foo {
                ...FooFragment
            }
        }
    }
}

fragment FooFragment on Foo {
    result
}
```
이 경우 `Bar`의 `foo` 필드 타입을 `FooWithJustResult`로 업데이트하면, 런타임에 `Foo` 객체를 기대하는 쿼리가 깨지게 됩니다. 이 예시에서는 스키마를 다음과 같이 재정의할 수 있습니다.

```graphql
type Query {
    foo: FullFoo
}

type FullFoo {
    bar: Bar
    result: Int
}

type Bar {
   foo: Foo
   result: Int
}

type Foo {
    result: Int
}
```
하지만 `bar` 필드를 필요로 하는 `Foo`에 대한 다른 프래그먼트들이 있다면 이 방법은 작동하지 않습니다.

## 더 복잡한 쿼리 세트

실제로 클라이언트가 순환 타입 참조에 의존하고 있다면 이를 제거하기는 매우 어렵습니다. 순환 타입 참조를 피하기 위해 클라이언트를 재작성하는 상당한 양의 작업을 수행하더라도(서버에 대체 GraphQL 필드를 구현해야 할 수도 있음), 기존 클라이언트들이 업데이트될 때까지 시간을 두어야만 최종적으로 순환 타입 참조를 제거할 수 있습니다.

스키마에서 순환 타입 참조를 제거하는 대신, 서버 런타임 체크를 통해 쿼리 복잡도를 제한하는 기술들이 있습니다. 표준 스키마 생성(예: [get-graphql-schema](https://github.com/prisma-labs/get-graphql-schema)) 및 검증(예: [TypeScript 컴파일러](https://github.com/microsoft/TypeScript)를 사용하는 [relay-compiler](https://relay.dev/docs/next/guides/compiler/)) 도구로는 서버와 클라이언트 간의 계약을 강제할 수 없으므로, 이러한 기술을 적용하기 전에 신중한 분석이 필요합니다.

GraphQL 웹사이트에서는 순환 타입 참조 문제를 피하기 위해 다음과 같은 기술들을 언급합니다.

* [깊이 제한(Depth limiting)](https://graphql.org/learn/security/#depth-limiting): 특정 깊이를 초과하는 쿼리 거부
* [쿼리 복잡도 분석(Query complexity analysis)](https://graphql.org/learn/security/#query-complexity-analysis): 처리 전 쿼리 비용을 계산하고 최대 비용을 초과하는 쿼리 거부

전체 GraphQL 스키마에 이러한 기술을 적용하면 단일 악성 쿼리가 입힐 수 있는 피해를 제한할 수 있습니다. 하지만 기존 애플리케이션의 경우 클라이언트가 깨지지 않도록 모든 가능한 쿼리에 대한 철저한 분석이 필요합니다. 클라이언트가 수행할 수 있는 최대 쿼리 깊이를 분석한 후에도, 이 제약 조건이 너무 느슨하여 악의적으로 조작된 요청이 서버를 다운시키는 것을 여전히 허용할 수도 있습니다. 쿼리 복잡도 분석은 더 일반적인 해결책이지만 조정해야 할 변수가 너무 많고, 사용 중인 서버에 호환되는 기성 구현체가 없다면 이를 직접 구현하는 데 많은 시간이 소요됩니다.

Clear에서 고안한 해결책은 이 두 기술 사이의 중간 형태였습니다. 바로 중첩된 쿼리 체인 내에서 특정 GraphQL 필드의 개수를 제한하는 것입니다. 이를 통해 순환 타입 참조를 형성하는 각 GraphQL 필드를 점진적으로 제거(deprecate)하면서 Clear 모바일 앱이 깨질지 여부를 훨씬 쉽게 파악할 수 있었습니다.

### 구현

Clear에서는 [juniper](https://github.com/graphql-rust/juniper) 크레이트를 사용하여 스키마의 각 GraphQL 타입에 대해 Rust 타입에 derive 및 절차적 매크로를 사용하여 GraphQL 서버를 구축합니다. 예시 스키마를 다음과 같이 구현할 수 있습니다.

```rust
use juniper::graphql_object;

/// 데이터베이스 커넥션 풀과 데이터 로더를 저장하는 데 사용됩니다.
struct Context;

impl Context {
    async fn get_bar(&self) -> Option<DbBar> {
        unimplemented!()
    }
    async fn get_foo(&self) -> Option<DbFoo> {
        unimplemented!()
    }
    async fn get_bar_result(&self) -> Option<i32> {
        unimplemented!()
    }
    async fn get_bar(&self) -> Option<i32> {
        unimplemented!()
    }
}

struct DbFoo;

struct DbBar;

/// `juniper::RootNode::new`에 전달되어 이를 루트 쿼리 타입으로 등록합니다.
struct Query;

#[graphql_object(context = Context)]
impl Query {
    async fn foo(&self, context: &Context) -> Option<Foo> {
        context.get_foo().await.map(|db_item| Foo {db_item})
    }
}

struct Foo {
    db_item: DbFoo
}

#[graphql_object(context = Context)]
impl Foo {
    async fn bar(&self, context: &Context) -> Option<Bar> {
        context.get_bar().await.map(|db_item| Bar {db_item})
    }
    async fn result(&self, context: &Context) -> Option<i32> {
        context.get_foo_result().await
    }
}

struct Bar {
    db_item: DbBar
}

#[graphql_object(context = Context)]
impl Bar {
    async fn foo(&self, context: &Context) -> Option<Foo> {
        context.get_foo().await.map(|db_item| Foo {db_item})
    }
    async fn result(&self, context: &Context) -> Option<i32> {
        context.get_bar_result().await
    }
}
```

깊이를 제한하기 위해, 주어진 GraphQL 객체에 도달하기까지 얼마나 많은 `foo` 및 `bar` 부모 필드가 이미 처리되었는지 추적할 수 있습니다. 그리고 `Foo` 객체를 처리하기 전 깊이가 3 이상이거나, `Bar` 객체를 처리하기 전 깊이가 2 이상인 경우(예시 클라이언트가 요구하는 최대치) 에러를 반환합니다.

```rust
use juniper::{FieldResult, FieldError};

#[graphql_object(context = Context)]
impl Query {
    async fn foo(&self, context: &Context) -> Option<Foo> {
        let db_item = context.get_foo().await?;
        Some(Foo {depth: 1, db_item})
    }
}

struct Foo {
    depth: usize,
    db_item: DbFoo,
}

#[graphql_object(context = Context)]
impl Foo {
    async fn bar(&self, context: &Context) -> FieldResult<Option<Bar>> {
        let Some(db_item) = context.get_bar().await else {
            return Ok(None)
        };
        if previous_depth >= 2 {
            log::warn!("깊이 제한 2 초과");
            return Err(FieldError::from("깊이 제한 초과"));
        }
        Some(Bar {depth: self.depth + 1, db_item})
    }
    async fn result(&self, context: &Context) -> i32 {
        context.get_foo_result().await
    }
}

struct Bar {
    depth: usize,
    db_item: DbBar,
}

#[graphql_object(context = Context)]
impl Bar {
    async fn foo(&self, context: &Context) -> FieldResult<Option<Foo>> {
        let Some(db_item) = context.get_foo().await else {
            return Ok(None)
        };
        if previous_depth >= 3 {
            log::warn!("깊이 제한 3 초과");
            return Err(FieldError::from("깊이 제한 초과"));
        }
        Some(Foo {depth: self.depth + 1, db_item})
    }
    async fn result(&self, context: &Context) -> i32 {
        context.get_bar_result().await
    }
}
```

이와 동일한 종류의 코드를 Clear의 백엔드 코드베이스 여러 곳에 적용해야 했으므로, 상용구 코드를 줄이기 위해 `impl_set_depth`라는 매크로를 작성했습니다. 이는 상위 트레이트인 `SetDepth` 트레이트를 구현함으로써 GraphQL 타입에 대해 `DepthLimited` 트레이트의 포괄적 구현(blanket implementation)을 가능하게 합니다. 구현된 모습은 다음과 같습니다:

```rust
macro_rules! impl_set_depth {
    ($graphql_item: path, $db_item:path, $depth_limit:expr) => {
        impl SetDepth for $graphql_item {
            type DbItem = $db_item;
            const DEPTH_LIMIT = $depth_limit;

            fn set_depth(&mut self, depth: usize) {
                self.depth = depth;
            }
        }
    }
}

trait SetDepth {
    type DbItem;
    const DEPTH_LIMIT: usize;

    fn set_depth(&mut self, depth: usize);
}

trait DepthLimited: SetDepth {
    fn increment_depth(db_item: SElf::DbItem, previous_depth: usize) -> Result<Self>
    where
        Self: Sized,
    {
        if previous_depth >= Self::DEPTH_LIMIT {
            log::warn!("깊이 제한 {} 초과", Self::DEPTH_LIMIT);
            bail!("깊이 제한 초과");
        }

    fn from_db_item(db_item: Self::DbItem, depth: usize) -> Self
    where
        Self: Sized
    }
}

impl<T> DepthLimited for T
where
    T: SetDepth,
    T::DbItem: Into<T>
{
    fn from_db_item(db_item: Self:DbItem, depth: usize) -> Self
    where
        Self: Sized,
    {
        let mut item = db_item.into();
        item.set_depth(depth);
        Ok(item)
    }
}
```

예시에 적용하면 다음과 같습니다:

```rust

#[graphql_object(context = Context)]
impl Query {
    async fn foo(&self, context: &Context) -> FieldResult<Option<Foo>> {
        let Some(db_item) = context.get_foo().await else {
            return Ok(None);
        };
        Some(Foo::increment_depth(db_item, 0)?)
    }
}

impl From<DbFoo> for Foo {
    fn from(db_item: DbFoo) -> Self {
        Self {
            db_item,
            depth: 0
        }
    }
}

impl_set_depth!(Foo, DbFoo, 3);

#[graphql_object(context = Context)]
impl Foo {
    async fn bar(&self, context: &Context) -> FieldResult<Option<Bar>> {
        let db_item = context.get_bar().await?;
        Ok(Some(Bar::increment_depth(db_item, self.depth)?))
    }
    async fn result(&self, context: &Context) -> i32 {
        context.get_foo_result().await
    }
}

impl From<DbBar> for Bar {
    fn from(db_item: DbBar) -> Self {
        Self {
            db_item,
            depth: 0
        }
    }
}

impl_set_depth!(Bar, DbBar, 2);

#[graphql_object(context = Context)]
impl Bar {
    async fn foo(&self, context: &Context) -> FieldResult<Option<Foo>> {
        let db_item = context.get_foo().await?;
        Ok(Some(Foo::increment_depth(db_item, self.depth)?))

    }
    async fn result(&self, context: &Context) -> i32 {
        context.get_bar_result().await
    }
}
```

이렇게 하면 [앞서 본 것과 같은](#임의로 깊은 쿼리) 더 깊은 쿼리는 방지하면서, [프래그먼트가 포함된 쿼리](#프래그먼트가 포함된 쿼리)는 정상적으로 서비스할 수 있습니다.

# 결과

이 기술만으로도 Clear의 공개 GraphQL 서버에서 모바일 앱을 깨뜨리지 않고 임의로 깊은 쿼리가 처리되는 것을 방지할 수 있었습니다. 저희는 순환 타입 참조를 일으키는 모든 GraphQL 필드를 식별하고, 모바일 앱이 수행할 수 있는 쿼리 내에서 해당 필드들이 얼마나 깊게 중첩되는지 분석했습니다. 이 분석을 통해 순환 타입 참조의 일부인 각 GraphQL 객체에 대해 적절한 깊이 제한을 도출할 수 있었습니다. 또한 이 분석을 돕기 위한 [도구](https://gitlab.com/haut-technologies/graphql-analyzer)도 만들었습니다.

또 다른 도구도 개발되었습니다. GraphQL 스키마를 파싱하여 가능한 가장 비싼 쿼리를 자동으로 구성한 다음, 머지 리퀘스트 파이프라인의 일부로 리뷰 환경에서 실행 중인 GraphQL 서버에 부하 테스트를 수행합니다. 이를 통해 DOS 공격을 방지하기 위해 GraphQL 서버에 설정해야 할 요청 속도 제한(rate limit)을 알 수 있을 뿐만 아니라, 데이터 로더 구현과 같은 성능 개선 사항의 영향을 측정할 수 있습니다.
