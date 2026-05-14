+++
draft = false
title = "Hyperview와 Rust를 활용한 React Native 모바일 앱의 서버 사이드 렌더링(SSR) 구현기"
date = "2026-05-11"
[taxonomies]
authors = ["Charles Johnson"]
tags = ["rust", "hyperview", "React Native"]
+++

## 서론

안녕하세요, [Clear](https://getclearapp.com).의 CTO Charles입니다.
제가 개발하고 있는 모바일 앱의 일부 기능을 Rust를 사용하여 서버 사이드 렌더링(SSR)으로 구현한 경험을 공유하고자 합니다. 먼저, 제가 왜 이런 선택을 하게 되었는지 배경부터 설명해 드릴게요.

## 동기

신규 사용자들에게 Clear가 어떤 앱인지 명확히 알리고, 앱의 다양한 기능을 쉽게 발견할 수 있도록 하기 위해 각 기능의 티저를 제공하는 제대로 된 "홈 탭(Home tab)"이 필요했습니다.
기존에는 신규 사용자가 가입 절차를 마치면 커뮤니티 게시글 목록이 보이는 "홈 탭"으로 이동했습니다.
하지만 커뮤니티 기능을 사용하는 유저가 전체의 5% 미만이었고, Clear는 무엇보다 '여러 스킨케어 제품들의 정보를 공유'하는 앱이기 때문에 홈 탭에서 커뮤니티 게시글만 보여주는 것은 앞뒤가 맞지 않았습니다.
당시 "트래커 탭"은 사용자의 루틴 목록과 진행 상황 체크인만 보여주고 있어 그리 매력적이지 않았고, 이를 첫 번째 탭으로 설정하는 것도 효과적이지 않았습니다.

| 기존 홈 탭 | 기존 트래커 탭 |
| :---: | :---: |
|![What the Home tab looked like in 2023](https://uploads.getclearapp.com/website_assets/screenshots/feed.png) | ![What the diary looked like in 2023](https://uploads.getclearapp.com/website_assets/screenshots/diary.png) |

새로운 홈 탭의 기본 구조는 사용자의 활동에 따라 동적으로 변하는 이종(heterogenous) 컴포넌트 목록이었습니다. 이는 알림 내역 화면과 유사한 문제였는데, 각 알림 항목을 렌더링하기 위해 서로 다른 유형의 데이터가 필요했기 때문입니다.

| 새로운 홈 탭 초기 디자인 | 알림 내역 화면 |
| :---: | :---: |
| ![Initial Design for the new Home tab](https://uploads.getclearapp.com/blog_assets/Diary.png) | ![Notification History Screen](https://uploads.getclearapp.com/blog_assets/Notification.jpg)|

저희는 GraphQL Union 타입을 페이지네이션된 목록으로 반환하고 있었고, 프론트엔드 코드는 이를 어떻게 렌더링할지 알고 있어야 했습니다.
문제는 GraphQL Union에 새로운 타입을 추가하고 싶을 때 발생했습니다. 앱의 구버전이 이를 처리하지 못해 에러가 발생할 수 있다는 것을 깨달았죠.
클라이언트에서 알 수 없는 타입을 필터링한다 하더라도, 서버는 앱 버전이 지원하는 타입을 알아야 올바른 페이지네이션을 처리할 수 있습니다. 그렇지 않으면 호환되는 타입을 찾을 때까지 여러 페이지를 계속 불러와야 할 수도 있기 때문입니다.
저희는 클라이언트가 Notifications 객체의 scalableConnection 필드에 지원하는 알림 타입 목록을 전달하게 함으로써 이 문제를 해결했습니다. 홈 탭에도 비슷한 접근 방식을 적용할 수 있었습니다.

### 알림 내역 데이터를 가져오기 위한 GraphQL 쿼리
```graphql
query {
  viewer {
    userNotifications {
      scalableConnection(
        allowedTypes: [
          FOLLOWEES_POST
          FOLLOW
          POST_UPVOTE
        ]
      ) {
        edges {
          node {
            typename: __typename
            ... on FolloweesPost {
              ...SingleNotificationFolloweesPostFragment
            }
            ... on FollowNotification {
              ...SingleNotificationFollowFragment
            }
            ... on PostUpvoteNotification {
              ...SingleNotificationPostUpvoteFragment
            }
          }
        }
      }
    }
  }
}
```

## 왜 기존 GraphQL API를 확장하지 않았나요?

저희 디자이너는 일주일에 한 시간만 저희와 협업하고 있었기 때문에, "홈 탭"의 완전하고 전문적인 디자인을 확정하는 데 시간이 오래 걸릴 수밖에 없었습니다.
디자인이 계속 바뀌는 상황에서 너무 일찍 GraphQL API를 확장하려고 했다면, 출시되지도 않을 기능을 위해 백엔드를 준비하는 데 엄청난 개발 시간을 낭비했을 것입니다.
또한, 디버그 빌드 시 GraphQL 서버의 변경 사항을 다시 컴파일하는 데 최대 1분이 소요되어 GraphQL API로 풀스택 개발을 하는 것이 비현실적인 상황이었습니다.
원래의 바이너리 크레이트를 더 작은 크레이트들로 분리하고, GraphQL 필드 리졸버 내에서 juniper 매크로가 데이터베이스 쿼리 코드를 직접 소비하지 않도록 하여 타입 재귀(type recursion) 폭발을 막으려 노력하며 핫 컴파일 시간을 줄이려 애쓰고 있었습니다.

이러한 노력 덕분에 rust-analyzer를 사용할 만한 수준까지는 왔지만, cargo watch를 실용적으로 사용할 수 있을 만큼 컴파일 시간을 단축하려면 백엔드 코드베이스 대부분을 리팩토링해야 했습니다.
당시 유일한 소프트웨어 엔지니어였던 저로서는 이 리팩토링에만 매달릴 여력이 없었습니다. 이제 기존 GraphQL 서버를 대체할 대안을 실험해 볼 때가 된 것이죠.

타입 재귀 문제에 대한 자세한 내용은 [이 블로그 포스트](../when-type-recursion-gets-out-of-control/)를 참고하세요.


## 가능한 해결책들

### 홈 탭 전용 GraphQL 서버

[어드민 사이트](https://getclearapp.com/admin)에서 했던 것처럼 별도의 GraphQL 서버를 만들어 GraphQL을 유지하면서 컴파일 시간 문제를 피할 수도 있었습니다.
하지만 저희가 사용하는 GraphQL 클라이언트인 Relay는 애플리케이션당 단일 GraphQL 서버를 가정합니다. 이미 공용 API와 어드민 API를 혼용해서 사용하던 어드민 사이트에서 타입 체크 오류(쿼리를 올바른 클라이언트에 전달해야 하고 이름 충돌을 피해야 함)가 발생하며 문제가 된 적이 있었습니다.

### 페더레이션(Federated) GraphQL 서버

여러 바이너리 서버를 실행하면서 하나의 GraphQL 엔드포인트처럼 동작하게 하는 GraphQL Federation 방식을 고려할 수 있었습니다.
하지만 `juniper`는 페더레이션을 지원하지 않습니다. [federation](https://async-graphql.github.io/async-graphql/en/apollo_federation.html)을 포함해 훨씬 더 많은 기능을 지원하는 `async-graphql`로 마이그레이션할 수도 있었겠지만, 이는 공용 서버와 어드민 서버 모두를 업데이트해야 하는 작업이었습니다(두 서버 모두 `juniper` 트레이트를 파생하는 공통 타입을 공유하기 때문입니다). 이 작업의 규모는 컴파일 이슈를 위해 리팩토링하는 것과 맞먹는 수준이었습니다.

### React 컴포넌트의 서버 사이드 렌더링

Next.js나 Remix 같은 인기 있는 웹 프레임워크는 `react-dom/server` API를 사용해 React 컴포넌트를 HTML로 서버 사이드 렌더링합니다. 

하지만 React Native에는 이와 동등한 프레임워크가 없었습니다. React 컴포넌트가 네이티브 UI 컴포넌트에 매핑되기 때문에 HTML처럼 하이퍼미디어로 표현하기 어렵기 때문입니다.

### Hyperview

우연하게 [하이퍼미디어 시스템 책](https://hypermedia.systems/hyperview-a-mobile-hypermedia/))을 읽다가 저는 Hyperview를 발견했습니다.
이는 서버에서 생성된 XML 응답을 받아 컴포넌트를 렌더링하는 React Native 클라이언트입니다. 서버 요건은 Rust의 `axum`이나 다른 HTTP 서버 크레이트, 그리고 XML 템플릿 렌더링을 위한 `askama`를 사용하면 쉽게 충족할 수 있었습니다.
Hyperview 클라이언트가 기대하는 [스타일링](https://hyperview.org/docs/reference_styles)과 기본 요소들이 React Native와 직접 매핑되므로 학습 난이도도 그다지 높지 않았습니다.
기존 React 컴포넌트를 재사용하고 싶다면 클라이언트에서 커스텀 [엘리먼트(elements)](https://hyperview.org/docs/reference_custom_elements)로 등록할 수 있지만, 이는 버전 관리 문제를 야기합니다.
클라이언트는 초기 응답을 받기 위한 Hyperview 서버의 엔드포인트만 알면 되며, 서버는 버튼 클릭이나 [폼(forms)](https://hyperview.org/docs/reference_form)을 위한 `href`를 제공합니다.
모바일 앱 전체를 이런 방식으로 개발할 수도 있지만, Clear처럼 이미 다른 화면으로의 내비게이션이 필요한 기존 앱의 경우 Hyperview 클라이언트를 기존 내비게이터에 연결하고 `href`를 내비게이션 경로로 활용할 수 있습니다.
저희는 홈 탭을 위해 기존의 복잡한 컴포넌트를 재사용하지 않았기에 커스텀 엘리먼트가 필요 없었고, 덕분에 복잡성을 낮출 수 있었습니다.

### OpenAPI 스펙을 갖춘 JSON API

이전 회사에서 OpenAPI 스펙으로부터 React Native 앱용 TypeScript 클라이언트를 생성해 본 경험은 있었지만, [`dropshot`](https://docs.rs/dropshot/latest/dropshot/)을 사용해 자동으로 OpenAPI 스펙을 생성해 본 적은 없었습니다.
이 방식도 괜찮았겠지만, GraphQL이 제공하는 '클라이언트가 요청한 데이터만 받는' 장점을 잃게 됩니다. Hyperview와 달리 JSON API로는 어떤 컴포넌트의 로딩을 지연시킬지, 예상치 못한 에러를 어떻게 보여줄지 등을 자연스럽게 표현하기가 더 어렵습니다.

저는 하이퍼미디어 시스템 책에서 읽은 [HATEOAS](https://hypermedia.systems/components-of-a-hypermedia-system/#_hypermedia_as_the_engine_of_application_state_hateoas) 개념에 큰 영향을 받았습니다.
'애플리케이션 상태의 엔진으로서의 하이퍼미디어(Hypermedia As The Engine Of Application State)'는 초기 웹 개념이지만, Hyperview는 이를 모바일 앱에 적용하여 익숙한 데이터 API의 대안으로 새로운 생명력을 불어넣었습니다. UI 표현을 위해 JSON 대신 XML을 사용하는 이유는 [이 블로그 포스트](https://hyperview.org/blog/#example-1-list-of-users)에 잘 설명되어 있습니다.

## 구현

저희는 Hyperview로 홈 탭을 구축하기로 결정했고, 기존 UI 컴포넌트를 재사용하지 않고도 첫 번째 버전을 출시했습니다.

`axum`과 `askama`를 사용해 XML 응답을 보내는 Hyperview 서버를 구축하는 작업은 순조로웠습니다. 딱 하나 주의할 점은 "Content-Type" 헤더를 반드시 "application/vnd.hyperview+xml"로 설정해야 한다는 것이었습니다. 그렇지 않으면 `hyperview` 클라이언트에서 `Error`가 발생합니다.


<details>
<summary>
Minimal example of hyperview server in Rust
</summary>

```rust
use std::net::SockerAddr;

use askama::Template;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::get,
    Router,
    Server
};

#[tokio::main]
async fn main() {
    let state = HyperviewState;
    let app = Router::new()
        .route("/hyperview/home", get(home))
        .with_state(state);
    Server::bind(&SockerAddr::from(([0, 0, 0, 0], 2000)))
        .serve(app.into_make_service())
        .await.unwrap();
}

// Can contain database pool etc.
struct HyperviewState;

async fn home(state: HyperviewState) -> Result<(HeaderMap, String), StatusCode> {
    let mut response_headers = HeaderMap::new();
    response_headers.insert(
        "Content-Type",
        "application/vnd.hyperview+xml".parse().unwrap()
    );
    let hxml = HomeDocTemplate {
        message: "hello"
    }.to_string();
    Result::<_, StatusCode>::Ok((response_headers, hxml))
}

#[derive(Template)]
#[template(path = "home/doc.xml")]
struct HomeDocTemplate {
    message: &'static str
}
```
</details>

XML 응답은 [HXML](https://hyperview.org/docs/guide_html) 형식이어야 합니다. 최상위 `view`에 `refresh` 트리거를 추가해두면, 로컬 서버에 연결한 상태에서 앱 전체를 다시 로드하지 않고도 UI를 실시간으로 수정하며 확인할 수 있어 편리합니다.

<details>
<summary>Minimal HXML</summary>

```xml
<doc xmlns="https://hyperview.org/hyperview">
  <screen
    id="home"
  >
    <styles>
      <style
        id="GreetingText"
        fontSize="26"
      />
    </styles>
    <body>
      <view
        id="home_view"
        trigger="refresh"
        action="reload"
        scroll="true"
        show-scroll-indicator="false"
        style="HomeView"
      >
        <text style="GreetingText">
          {{ message }}
        </text>
      </view>
    </body>
  </screen>
</doc>
```
</details>

The hyperview client was rendered as a screen within Clear's existing navigation.

<details>
<summary>Minimal React Native code</summary>


```tsx
import Hyperview from "hyperview";
const components = []; // Without any custom components

// Used as a screen within "react-navigation"
function Home() {
    return (
        <Hyperview
            components={components}
            entrypointUrl="https://getclearapp.com/hyperview/home"
            fetch={fetch}
        />
    )
}
```
</details>

## 배운 점들

### 커스텀 엘리먼트 등록의 필요성

출시된 홈 탭의 초기 버전조차도 HXML에서 HTML처럼 SVG 그래픽을 렌더링하기 위해 커스텀 엘리먼트를 사용했습니다. 현재는 `<svg>`와 `<path>` 엘리먼트만 지원되는데, Figma에서 만든 그래픽을 표현하기에는 충분했습니다.

<details>
<summary>React Native code to register SVG elements.</summary>

```tsx
import Svg, { Path } from "react-native-svg";
import React, { PureComponent } from "react";
import Hyperview, { HyperviewProps } from "@charles-johnson/hyperview";

export default class HyperviewSvg extends PureComponent<HyperviewProps> {
  static namespaceURI = "http://www.w3.org/2000/svg";

  static localName = "svg";

  render() {
    const { element, stylesheets, options, onUpdate } = this.props;
    // Parses the HXML elements attributes.
    // Returns styles and custom props.
    const props = Hyperview.createProps(element, stylesheets, options);
    // Render any HXML sub-elements using Hyperview.
    const children = Hyperview.renderChildren(
      element,
      stylesheets,
      onUpdate,
      options
    );
    return <Svg {...props}>{children}</Svg>;
  }
}

export default class HyperviewSvgPath extends PureComponent<HyperviewProps> {
  static namespaceURI = "http://www.w3.org/2000/svg";

  static localName = "path";

  render() {
    const { element, stylesheets, options } = this.props;
    // Parses the HXML elements attributes.
    // Returns styles and custom props.
    const props = Hyperview.createProps(element, stylesheets, options);
    return <Path {...props} />;
  }
}
```
`HyperviewSvg`와 `HyperviewSvgPath`는 `Hyperview` 엘리먼트의 `components` prop에 포함되어야 합니다. 
</details>

결국 나중에는 앱의 이후 버전을 위해 커스텀 엘리먼트를 등록하기 시작했고, 구버전 앱의 응답에는 이를 포함하지 않도록 처리해야 했습니다. 이를 통해 기존의 복잡한 UI 컴포넌트를 재사용할 수 있었고, React에만 익숙한 다른 팀원들도 새로운 UI 컴포넌트를 만들 수 있게 되었습니다.

저희는 앱이 버전 정보를 포함한 User-Agent HTTP 헤더를 보내도록 하여 서버가 호환성을 확인할 수 있게 했습니다. 이로 인해 코드베이스 곳곳에 각 커스텀 엘리먼트의 최소 버전을 확인하는 로직이 흩어지게 되었고, GraphQL API처럼 자동화된 검증 절차는 갖추지 못했습니다. 실무에서는 리뷰 환경에서 Hyperview 변경 사항을 앱 버전별로 직접 테스트했기 때문에 운영상의 버그로 이어지지는 않았습니다.

<details>
<summary>Example of version check on the server</summary>

```rust
async fn home(request_headers: HeaderMap, state: HyperviewState) -> Result<(HeaderMap, String), StatusCode> {
    let custom_section_header = is_compatible_with_version(&request_headers, 1, 52);
    let mut response_headers = HeaderMap::new();
    response_headers.insert(
        "Content-Type",
        "application/vnd.hyperview+xml".parse().unwrap()
    );
    let hxml = HomeDocTemplate {
        custom_section_header,
        message: "hello"
    }.to_string();
    Result::<_, StatusCode>::Ok((response_headers, hxml))
}

#[derive(Template)]
#[template(path = "home/doc.xml")]
struct HomeDocTemplate {
    custom_section_header: bool,
    message: &'static str
}
```
</details>

이러한 커스텀 제품(products)을 렌더링하기 위해 XML 템플릿은 React 코드에서 사용된 `namespaceURI`와 일치하는 네임스페이스를 선언해야 합니다.

<details>
<summary>Example of conditionally rendering custom element using namespace prefix</summary>

```xml
<doc xmlns="https://hyperview.org/hyperview" xmlns:clear="https://getclearapp.com/hyperview">
  <screen
    id="home"
  >
    <styles>
      <style
        id="GreetingText"
        fontSize="26"
      />
    </styles>
    <body>
      <view
        id="home_view"
        trigger="refresh"
        action="reload"
        scroll="true"
        show-scroll-indicator="false"
        style="HomeView"
      >
        {% if custom_section_header %}
        <clear:section-header
          title="{{ message }}"
        />
        {% else %}
        <text style="GreetingText">
          {{ message }}
        </text>
        {% endif %}
      </view>
    </body>
  </screen>
</doc>
```
</details>

### 공식 Hyperview 클라이언트 포크(Fork)의 필요성

* 당시 React Native Hyperview 클라이언트의 최신 버전은 v0.72.3이었으나, 이는 구버전 React Native(v0.67) 및 React(v17) 기반이어서 이 [커밋](https://github.com/Instawork/hyperview/commit/a221a905bddff16f984813747e603e89a80b3f9c)을 통해 업데이트가 필요했습니다.
* Clear 앱에서 사용할 수 있는 TypeScript 선언 파일이 없었습니다. 이는 이 [커밋](https://github.com/Instawork/hyperview/commit/db1b999cf38a71e38b04cb6aa53e17951b07a25e)으로 해결했습니다.
* `@react-native-picker/picker`가 당시 React Native 0.72를 지원하지 않았기 때문에, 필요 없었던 `picker-field` 엘리먼트를 이 [커밋](https://github.com/Instawork/hyperview/commit/ecf77b6196cfb7258e7ce0a953885a3b4d90c4e3)에서 제거했습니다.
* 공식 Hyperview 클라이언트는 GET과 POST 메소드만 허용했지만, 딱히 그럴 이유가 없었기에 PUT, PATCH, DELETE 메소드도 사용할 수 있도록 이 [[[[[[커밋](https://github.com/Instawork/hyperview/commit/1cb4c6db49b0e5b0b2f73c0491cf1a9300cee528)에서 수정했습니다. 덕분에 시맨틱하게 적절한 HTTP 요청을 보낼 수 있게 되었습니다.
* 당겨서 새로고침(Pull-to-refresh)은 `refresh` 트리거로 쉽게 구현할 수 있지만, `shows-scroll-indicator` 속성을 무시하는 버그가 있어 이 [커밋]((https://github.com/Instawork/hyperview/commit/f26040c38db84a8f5117f359c98cf605817041c5)에서 수정했습니다. 이 수정 사항은 이 이슈로 보고된 후 업스트림에 반영되었습니다.
* `visible` 트리거는 리스트의 지연 로딩(lazy loading)에 유용하지만, 안드로이드에서 동작이 일관되지 않는 문제가 [이 이슈](https://github.com/Instawork/hyperview/issues/780))로 보고되었고 이 [커밋](https://github.com/Instawork/hyperview/commit/df60795f570eedfde81d985f389ba85065e1976f)을 통해 해결되었습니다.

### Hyperview의 이벤트 시스템 활용

루틴 생성이나 진행 상황 체크인처럼 Hyperview 외부에서 발생한 사용자 상호작용 이후에도 홈 탭을 최신 상태로 유지하기 위해, HXML 속성 대신 JavaScript를 통해 이벤트를 디스패치해야 했습니다.

<details>
<summary>Example of dispatch via Javascript</summary>

```js
import { dispatch } from "@charles-johnson/hyperview/lib/services/events"

dispatch("routine-update");
```
</details>


<details>
<summary>Example of HXML that updates on events</summary>

```xml
<view
  href="/hyperview/home?only=current_routine"
  trigger="on-event"
  event-name="routine-update"
  action="replace"
  xmlns="https://hyperview.org/hyperview"
  xmlns:clear="https://getclearapp.com/hyperview"
>
  <clear:routine-block routine="{{ routine }}" />
</view>
```
</details>

### 외부 내비게이션 연결 작업

내비게이션 액션이 있는 엘리먼트의 `href` 속성을 파싱하여 기존 내비게이션 경로에 매핑하는 방법이 필요했습니다. 내비게이션 경로와 파라미터는 ````zod`를 통해 검증하여 에러를 조기에 발견할 수 있도록 했습니다.
다만, 이제는 내비게이션 시스템에 파괴적 변경(경로 이름 변경이나 파라미터 삭제 등)이 생기지 않도록 주의해야 합니다. 운영 중 에러가 발생한 적은 없지만, Hyperview 시스템을 잘 모를 수 있는 프론트엔드 팀원들과 긴밀한 소통이 필요한 부분입니다.
Hyperview 클라이언트는 내비게이션 파라미터 없이 화면을 이동할 수 있도록 v0.72.3에서 포크되어 이 [커밋](https://github.com/Instawork/hyperview/commit/6ffc8f2cd3d6d0ad7d8413749f2c2d9bca0b6168)에서 수정되었습니다. 이 [이슈](https://github.com/Instawork/hyperview/issues/779) 보고 이후, 공식 Hyperview 프로젝트는 이 [블로그](https://hyperview.org/blog/#:~:text=With%20this%20solid%20foundation%20in%20place%2C%20we,us%20to%20focus%20on%20a%20single%20solution.)에 언급된 것처럼 자체 내부 내비게이션에 집중하기 위해 외부 내비게이션 지원을 제거했습니다. 이는 Hyperview 기반으로 전체 앱을 구축하는 경우에 더 유용합니다.

### 커스텀 엘리먼트 속성 검증

대부분의 커스텀 엘리먼트 데이터는 JSON 문자열로 직렬화하여 단일 속성 값으로 전달했습니다. 이 속성은 런타임에 JavaScript 객체로 파싱되고 `zod`에 의해 검증됩니다.
이를 통해 타입 에러를 빠르게 잡을 수 있지만, HXML 응답으로 직렬화되는 Rust 타입과 zod 파서를 자동으로 동기화할 방법은 아직 없습니다.

커스텀 엘리먼트 등록 시 일반적인 검증 로직:

```tsx
class HyperviewRoutineBlock extends PureComponent<HyperviewProps> {
    static namespaceURI = "https://getclearapp.com/hyperview"

    static localName = "routine-block"

    render() {
        const { element, stylesheets, options } = this.props;
        // Parses the HXML elements attributes.
        // Returns styles and custom props.
        const props = Hyperview.createProps(element, stylesheets, options);
      try {
        if (!("routine" in props)) {
          throw new Error("routine-block missing required routine attribute");
        }
        if (typeof props.routine !== "string") {
          throw new Error(
            `routine-block routine attribute has type "${typeof props.routine}", not "string"`
          );
        }
        const routine = routineSchema.parse(JSON.parse(props.routine));
        return (
          <RoutineBlock routine={routine} />
        );
      } catch (e) {
          /// TODO: Track error
          null
      }

    }
}
```
`routineSchema`는 `zod` 스키마이며, `routine` 속성은 Rust 코드에서 JSON으로 직렬화됩니다.
```rs
use std::fmt::{Formatter, Result};

struct Routine {
    products: Vec<Product> // Product implements Serialize
    // other fields that might require special serialization
}

impl Display for Routine {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result {
        let mut json = json!({
            "products": self.products,
        });
        write!(f, "{json}")
    }
}
```

### HXML 스키마를 활용한 XML 검증

HXML 스키마에 맞는 XML을 올바르게 작성하기 위해, VSCode XML 확장 프로그램에서 [이곳](https://github.com/Instawork/hyperview/tree/master/schema)에 있는 .xsd 파일을 사용하도록 설정하는 것이 오타 방지에 큰 도움이 되었습니다.
하지만 `askama` 템플릿 구문 때문에 가짜 양성(false positives) 에러가 너무 많이 발생하여, 견고한 CI 작업으로 활용하기에는 무리가 있었습니다.





---
원본: [https://seoul.rs/](https://seoul.rs/blog/server-side-rendering-mobile-app-with-rust/)
LLM(Google Gemini)의 도움을 받아 @seungjin의 의해 한글로 번역된 글입니다.
