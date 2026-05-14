+++
draft = false
title = "타입 재귀가 통제 불능이 될 때"
date = "2026-04-19"
[taxonomies]
authors = ["Charles Johnson"]
tags = ["rust", "async", "compile time"]
+++

# 들어가며

안녕하세요, Charles입니다. 이번에는 현업에서 겪었던 Rust의 긴 컴파일 시간 문제에 대해 공유하고자 합니다. 온라인에서 볼 수 있는 컴파일 시간 단축에 대한 대부분의 조언은 다음과 같은 표준적인 해결책들을 제시합니다:
    
- 3rd party 의존성 컴파일: 로컬에서는 cargo를 사용해도 괜찮지만, CI에서는 cargo-chef나 sccache를 사용하기
- 크레이트 컴파일: 워크스페이스를 사용하고 워크스페이스 의존성 그래프를 병렬화하여, 하나의 큰 크레이트를 하나의 프로세스로 컴파일하는 대신 여러 개의 작은 크레이트를 병렬 프로세스로 컴파일하기
- 링커: mold와 같은 대안 링커를 사용하기

더 깊이 들어가자면, fasterthanlime의 블로그 포스트인 [Why is my rust build so slow](https://fasterthanli.me/articles/why-is-my-rust-build-so-slow)를 참고할 수 있습니다. 그는 `warp`가 매우 큰 타입을 생성하는 경향과 제네릭 타입의 단형성화(monomorphisation) 비용 문제를 보여주었으며, 컴파일 시간을 디버깅하기 위한 다양한 도구들을 소개했습니다.

하지만 제가 찾은 블로그들 중 어느 것도 제가 현업에서 직면한 문제의 핵심을 짚어주지 못했기에, 비슷한 상황을 겪는 다른 분들이 적용할 수 있도록 제 경험을 공유하고자 합니다.

# 문제

[Clear](getclearapp.com)에서 GraphQL 서버를 컴파일할 때 간간히 보이는 빌드 실패가 여간 고통이 아니였습니다. 이때 발생하는 `overflow evaluating the requirement` 에러는 외부 라이브러리(3rd party)의 제네릭 타입에 깊이 감싸진 타입을 대상으로 하고 있었지만, 그 근본 원인은 GraphQL 타입을 위한 juniper::graphql_object 매크로 호출에 있었습니다. 정확히 동일한 코드를 다시 빌드하려고 하면 또 성공하기도 했고 그야말로 뒤죽박죽 이였습니다.

# 하나의 크레이트를 여러 개로 나누기

나중에 저는 원래의 바이너리 크레이트인 `clear-server`를 여러 라이브러리 크레이트로 나눴습니다 (나중에는 GraphQL 서버에 사용되지 않는 다른 바이너리 크레이트들도 분리했습니다). 그런 다음 `juniper::graphql_object` 호출을 세 개의 라이브러리 크레이트로 격리했습니다: `clear_public_graphql_api` (모바일 앱용 GraphQL API 전용 타입), `clear_admin_graphql_api` (관리자 패널용 GraphQL API 전용 타입), 그리고 `clear_shared_graphql_api` (모바일 앱과 관리자 패널 공통 타입). `juniper`에 의존하지 않지만 데이터베이스와 상호작용하는 나머지 코드는 `clear_db_client` 크레이트로 분리했습니다.

다음은 워크스페이스 크레이트 의존성 그래프의 모습입니다.

{% mermaid() %}

graph TD
A(clear-server) --> B(clear_public_graphql_api)
A --> C(clear_admin_graphql_api)
B --> D(clear_shared_graphql_api)
C --> D
A --> E(clear_db_client)
B --> E
C --> E
D --> E
{% end %}

`lib.rs` 상단에 `#![recursion_limit = 1024]`와 같이 `recursion_limit`을 기본값 128에서 `clear_public_graphql_api`는 1024로, `clear_admin_graphql_api`는 256으로 늘린 이후로는 오버플로우가 발생하지 않았습니다. 하지만 여전히 `clear_public_graphql_api`가 다른 크레이트보다 눈에 띄게 컴파일이 오래 걸리는 것을 관찰했으며, 이는 재귀 깊이가 컴파일 시간의 병목 현상임을 나타내었습니다.

`clear_public_graphql_api`의 재귀 제한을 49 정도로 훨씬 낮게 설정하면 디버그 빌드에서 에러를 재현할 수 있습니다. 이 경우 최상위 에러 메시지는 `overflow evaluating the requirement &str: Sync`입니다. 이는 이미지 URL을 데이터베이스에 삽입하는 애플리케이션 코드에서 발생하며, `Mutation` 타입에 대한 `graphql_object` 매크로 호출이 이에 직접적으로 의존하고 있습니다. 

# 제어의 역전(IoC)을 통한 크레이트 의존성 그래프 평탄화

데이터베이스 상호작용을 위한 트레이트 메서드를 가진 트레이트 객체를 GraphQL 컨텍스트 타입에 추가함으로써, `graphql_object` 매크로 호출에서 데이터베이스 쿼리 코드에 대한 의존성을 제거할 수 있습니다.

예를 들어, 아래 코드에 타입 재귀 문제가 있다면,
```rust
use juniper::{
    graphql_object,
    Context
};
use diesel::{
    r2d2::{Pool, ConnectionManager},
    pg::PgConnection,
    dsl::count_star
};
use crate::schema::users;

type PgPool = Pool<ConnectionManager<PgConnection>>;

struct MyContext {
    pool: PgPool,
}

impl MyContext {
    fn total_users(&self) -> i32 {
        let mut conn = self.pool.get().unwrap();
        let total_users: Result<i32, _> = users::table.select(count_star())
            .first::<i64>(&mut conn)
            .try_into();
        total_users.unwrap()
    }
}

impl Context for MyContext {}

struct MyType;

#[graphql_object(context = MyContext)]
impl MyType {
    fn foo(&self, ctx: &MyContext) -> i32 {
        ctx.total_users()
    }
}
```
다음과 같이 트레이트를 정의할 수 있습니다.
```rust
trait GraphQlContext {
    fn total_users(&self) -> i32;
}

struct DbContext {
    pool: PgPool,
}

impl GraphQLContext for DbContext {
    fn total_users(&self) -> i32 {
        let mut conn = self.pool.get().unwrap();
        let total_users: Result<i32, _> = users::table.select(count_star())
            .first::<i64>(&mut conn)
            .try_into();https://seoul.rs/blog/server-side-rendering-mobile-app-with-rust/
        total_users.unwrap()
    }
}
```
이 트레이트는 기존 GraphQL 컨텍스트 타입의 일부가 될 수 있습니다.
```rust
struct MyContext {
    pool: PgPool,
    dynamic_part: Arc<dyn DynContext>,
}

impl MyContext {
    fn total_users() -> i32 {
        ctx.dynamic_part.total_users()
    }
}
```

단순화를 위해 이 예제에서는 `async fn`을 사용하지 않았습니다(데이터베이스 연결을 동기적으로 가져오기 때문). 따라서 실제로는 타입 재귀가 문제가 되지 않을 것입니다. 타입 정보가 `fn` 블록 내에 캡슐화되기 때문입니다. 원래 코드베이스는 diesel 쿼리를 위해 비동기적으로 연결을 가져왔고, 이로 인해 대부분의 GraphQL 메서드가 `async fn`이어야 했습니다. 또한 `sqlx`를 사용하기 시작하면서 연결 획득과 쿼리 실행 모두 비동기로 이루어졌습니다. `async fn`은 블록 내의 내용에 따라 고유한 타입을 생성하기 때문에, 타입 정보가 호출 그래프 위로 전달되어 타입 재귀를 증가시킵니다.

저희가 이미 수행한 작업은 `clear_graphql_context` 크레이트에서 [`async-trait`](https://crates.io/crates/async-trait) 매크로를 사용하여 `GraphQLContext` 트레이트를 정의하고, 이를 `clear_db_graphql_context` 크레이트에서 `DbGraphQLContext`로 구현하는 것이었습니다. `clear_*_graphql_api` 크레이트들은 이 구현 크레이트에 의존하지 않습니다. 

의존성 그래프는 다음과 같습니다:

{% mermaid() %}
graph TD
A(clear-server) --> B(clear_public_graphql_api)
A --> C(clear_admin_graphql_api)
B --> D(clear_shared_graphql_api)
C --> D
A --> E(clear_db_client)
B --> E
C --> E
D --> E
B --> F(clear_graphql_context)
C --> F
D --> F
G(clear_db_graphql_context) --> F
G --> E
A --> G
A --> F
F --> E
{% end %}

# 결과

저희는 컴파일러로부터 타입 정보를 숨기기 위한 인터페이스로 `GraphQLContext` 트레이트를 사용하여 새로운 GraphQL 쿼리와 뮤테이션을 구현해 왔습니다. 이를 통해 `clear_db_graph_context` 크레이트의 애플리케이션 로직을 수정할 때 디버그 사이클이 단축되었으며, 통합 테스트를 위한 안정적인 인터페이스를 확보할 수 있었습니다. 

이미지 URL을 삽입하는 부분부터 시작하여 기존 GraphQL 리졸버들을 리팩토링하기 시작할 수도 있겠지만, GraphQL 컨텍스트에 대한 `Sync` 요구 사항을 평가하는 것조차 데이터베이스 풀 타입으로 인해 38 단계의 타입 재귀 깊이가 필요합니다. 하지만 추가적인 컴파일 시간 단축을 이끌어내기 위해서는 데이터베이스 풀에 직접 접근하는 대신 `GraphQLContext` 트레이트 객체를 통하도록 모든 개별 GraphQL 리졸버를 리팩토링해야 합니다. 이것이 제가 컴파일 시간 문제를 완전히 극복하려 하지 않고, 다른 블로그 게시물에서 설명할 대안적인 클라이언트-서버 아키텍처를 찾게 된 이유입니다.


---
원본: [https://seoul.rs/blog/when-type-recursion-gets-out-of-control/](https://seoul.rs/blog/when-type-recursion-gets-out-of-control/)  
LLM(Google Gemini)의 도움을 받아 @seungjin의 의해 한글로 번역된 글입니다.  